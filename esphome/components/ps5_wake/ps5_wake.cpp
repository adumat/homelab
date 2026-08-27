#include "ps5_wake.h"
#include "esphome/core/log.h"
#include <cstdio>

#ifdef USE_ESP32
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_bt_device.h"
#include "esp_gap_bt_api.h"
#include "esp_l2cap_bt_api.h"
#include "esp_mac.h"
#include "esp_system.h"
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#endif

namespace esphome {
namespace ps5_wake {

static const char *const TAG = "ps5_wake";

namespace {
volatile bool g_cap_done = false;
uint8_t g_cap_bda[6] = {0};
char g_cap_name[64] = "";

void gap_cb(esp_bt_gap_cb_event_t event, esp_bt_gap_cb_param_t *param) {
  // Only the connection events matter now. The inquiry/discovery branches were
  // removed along with scan(): a PS5 never advertises on its Bluetooth Accessories
  // screen — it scans — so inquiry can never find one, which a 0-device scan
  // confirmed on 2026-08-26.
  if (event == ESP_BT_GAP_ACL_CONN_CMPL_STAT_EVT) {
    // Fires when the link opens, BEFORE any pairing result. This is the event
    // capture mode exists for: the console reveals its address here even if the
    // pairing it attempts afterwards fails.
    const uint8_t *b = param->acl_conn_cmpl_stat.bda;
    snprintf(g_cap_name, sizeof(g_cap_name), "%s", "");
    memcpy(g_cap_bda, b, 6);
    g_cap_done = true;
    ESP_LOGI("ps5_wake", "ACL from %02X:%02X:%02X:%02X:%02X:%02X (stat=%d)", b[0], b[1], b[2], b[3],
             b[4], b[5], param->acl_conn_cmpl_stat.stat);
  } else if (event == ESP_BT_GAP_AUTH_CMPL_EVT) {
    // Carries the device name too, which is how we confirm it is the console
    // rather than some other Bluetooth device in the room.
    const uint8_t *b = param->auth_cmpl.bda;
    memcpy(g_cap_bda, b, 6);
    snprintf(g_cap_name, sizeof(g_cap_name), "%s", (const char *) param->auth_cmpl.device_name);
    g_cap_done = true;
    ESP_LOGI("ps5_wake", "AUTH from %02X:%02X:%02X:%02X:%02X:%02X name='%s' stat=%d", b[0], b[1],
             b[2], b[3], b[4], b[5], g_cap_name, param->auth_cmpl.stat);
  } else if (event == ESP_BT_GAP_PIN_REQ_EVT || event == ESP_BT_GAP_CFM_REQ_EVT) {
    ESP_LOGI("ps5_wake", "pairing request received (event %d) — address already captured", event);
  }
}

}  // namespace

void PS5Wake::setup() {
  const uint32_t heap = esp_get_free_heap_size();
  if (this->bt_mode_ == BT_MODE_ALWAYS_ON && heap < this->min_heap_) {
    ESP_LOGW(TAG,
             "free heap %u is below min_heap_for_always_on %u; staying down and "
             "behaving on-demand per wake",
             (unsigned) heap, (unsigned) this->min_heap_);
    this->publish_result_("always_on declined: low heap");
    return;
  }
  ESP_LOGCONFIG(TAG, "setup complete, free heap %u", (unsigned) heap);
}

void PS5Wake::dump_config() {
  ESP_LOGCONFIG(TAG, "PS5 Wake:");
  ESP_LOGCONFIG(TAG, "  bt_mode configured: %s",
                this->bt_mode_ == BT_MODE_ALWAYS_ON ? "always_on" : "on_demand");
  ESP_LOGCONFIG(TAG, "  bluetooth currently up: %s", YESNO(this->bt_ready_));
  ESP_LOGCONFIG(TAG, "  retries: %u", this->retries_);
  ESP_LOGCONFIG(TAG, "  min_heap_for_always_on: %u", (unsigned) this->min_heap_);
  ESP_LOGCONFIG(TAG, "  free heap now: %u", (unsigned) esp_get_free_heap_size());
}

void PS5Wake::publish_result_(const std::string &msg) {
  ESP_LOGI(TAG, "%s", msg.c_str());
  if (this->last_result_ != nullptr)
    this->last_result_->publish_state(msg);
}

bool PS5Wake::parse_mac_(const std::string &in, uint8_t out[6]) {
  if (in.size() != 17)
    return false;
  for (size_t i = 0; i < 6; i++) {
    const size_t p = i * 3;
    if (i < 5 && in[p + 2] != ':' && in[p + 2] != '-')
      return false;
    auto nib = [](char c) -> int {
      if (c >= '0' && c <= '9')
        return c - '0';
      if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
      if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
      return -1;
    };
    const int hi = nib(in[p]);
    const int lo = nib(in[p + 1]);
    if (hi < 0 || lo < 0)
      return false;
    out[i] = static_cast<uint8_t>((hi << 4) | lo);
  }
  return true;
}
bool PS5Wake::bt_up_(const uint8_t pad_mac[6]) {
  if (this->bt_ready_)
    return true;

  esp_err_t err = ESP_OK;
  // pad_mac == nullptr means "come up as ourselves, do not spoof". Capture mode
  // uses that deliberately: impersonating a pad the console already trusts risks
  // it auto-connecting instead of appearing as a new device, and risks disturbing
  // the real pad's bond — which is the thing this whole device depends on.
  if (pad_mac != nullptr) {
    // Spoofing MUST happen before controller init: the stack reads the base MAC
    // once, at init.
    err = esp_iface_mac_addr_set(pad_mac, ESP_MAC_BT);
    if (err != ESP_OK) {
      ESP_LOGE(TAG, "esp_iface_mac_addr_set failed: %s", esp_err_to_name(err));
      return false;
    }
  }

  esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
  cfg.mode = ESP_BT_MODE_CLASSIC_BT;
  err = esp_bt_controller_init(&cfg);
  if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
    ESP_LOGE(TAG, "controller_init failed: %s", esp_err_to_name(err));
    return false;
  }
  err = esp_bt_controller_enable(ESP_BT_MODE_CLASSIC_BT);
  if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
    ESP_LOGE(TAG, "controller_enable failed: %s", esp_err_to_name(err));
    return false;
  }
  err = esp_bluedroid_init();
  if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
    ESP_LOGE(TAG, "bluedroid_init failed: %s", esp_err_to_name(err));
    return false;
  }
  err = esp_bluedroid_enable();
  if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
    ESP_LOGE(TAG, "bluedroid_enable failed: %s", esp_err_to_name(err));
    return false;
  }

  // Never discoverable or connectable: this device only ever initiates.
  esp_bt_gap_set_scan_mode(ESP_BT_NON_CONNECTABLE, ESP_BT_NON_DISCOVERABLE);

  this->bt_ready_ = true;
  // pad_mac may legitimately be nullptr (capture mode comes up unspoofed), so this
  // MUST be guarded. Dereferencing it unconditionally here caused
  // "Fault - LoadProhibited" on the first capture attempt: the nullptr case was
  // handled for esp_iface_mac_addr_set above and then read through two lines later.
  if (pad_mac != nullptr) {
    ESP_LOGI(TAG, "bluedroid up, spoofing %02X:%02X:%02X:%02X:%02X:%02X", pad_mac[0], pad_mac[1],
             pad_mac[2], pad_mac[3], pad_mac[4], pad_mac[5]);
  } else {
    ESP_LOGI(TAG, "bluedroid up with our own address (not spoofing)");
  }
  return true;
}

void PS5Wake::bt_down_() {
  if (!this->bt_ready_)
    return;
  esp_bt_l2cap_deinit();
  esp_bluedroid_disable();
  esp_bluedroid_deinit();
  esp_bt_controller_disable();
  esp_bt_controller_deinit();
  this->bt_ready_ = false;
  ESP_LOGI(TAG, "bluedroid down, free heap %u", (unsigned) esp_get_free_heap_size());
}

void PS5Wake::wake() {
  // Runs on the ESPHome main loop. Must return promptly: validate, snapshot, and
  // hand off. The previous version did the whole sequence inline and crashed the
  // device — worst case it blocked for ~24s (10 attempts x 2s wait + backoffs),
  // which starves the loop and trips the watchdog. Observed as
  // "Fault - Unknown, Crashed core: 1" after a single failed wake.
  if (this->in_progress_) {
    this->publish_result_("wake already in progress");
    return;
  }
  if (this->pad_mac_text_ == nullptr || this->ps5_mac_text_ == nullptr) {
    this->publish_result_("no MAC entities bound");
    return;
  }
  if (!parse_mac_(this->pad_mac_text_->state, this->pad_)) {
    this->publish_result_("pad_mac is not a valid MAC");
    return;
  }
  if (!parse_mac_(this->ps5_mac_text_->state, this->ps5_)) {
    this->publish_result_("ps5_mac is not a valid MAC");
    return;
  }

  this->in_progress_ = true;
  this->publish_result_("waking...");

  // 6 kB: bt_up_ does controller+bluedroid init, which is not shallow.
  if (xTaskCreate(&PS5Wake::wake_task_, "ps5_wake", 6144, this, 5, nullptr) != pdPASS) {
    this->in_progress_ = false;
    this->publish_result_("could not start wake task");
  }
}

void PS5Wake::loop() {
  // The worker task cannot publish: ESPHome components are not thread-safe. It
  // leaves the message here and the main loop publishes it.
  if (this->captured_pending_) {
    this->captured_pending_ = false;
    if (this->ps5_mac_text_ != nullptr) {
      // Writing an entity must happen here, on the main loop — never from a task.
      this->ps5_mac_text_->publish_state(this->captured_);
      ESP_LOGI(TAG, "ps5_mac set to %s from capture", this->captured_);
    }
  }
  if (this->result_pending_) {
    this->result_pending_ = false;
    this->publish_result_(this->pending_);
  }
}

void PS5Wake::capture() {
  if (this->in_progress_) {
    this->publish_result_("busy");
    return;
  }
  this->in_progress_ = true;
  this->publish_result_("discoverable 90s — pick 'PS5-Wake' on the console");
  if (xTaskCreate(&PS5Wake::capture_task_, "ps5_cap", 6144, this, 5, nullptr) != pdPASS) {
    this->in_progress_ = false;
    this->publish_result_("could not start capture task");
  }
}

void PS5Wake::capture_task_(void *arg) {
  auto *self = static_cast<PS5Wake *>(arg);
  g_cap_done = false;

  // nullptr: come up as ourselves. See bt_up_ for why we must not spoof here.
  if (!self->bt_up_(nullptr)) {
    snprintf(self->pending_, sizeof(self->pending_), "capture: bluetooth failed to start");
  } else {
    esp_bt_gap_register_callback(gap_cb);
    esp_bt_gap_set_device_name("PS5-Wake");
    esp_err_t err = esp_bt_gap_set_scan_mode(ESP_BT_CONNECTABLE, ESP_BT_GENERAL_DISCOVERABLE);
    if (err != ESP_OK) {
      ESP_LOGE(TAG, "set_scan_mode failed: %s", esp_err_to_name(err));
      snprintf(self->pending_, sizeof(self->pending_), "capture: could not go discoverable");
    } else {
      ESP_LOGI(TAG, "discoverable as 'PS5-Wake' for 90s — select it on the console");
      for (int i = 0; i < 180 && !g_cap_done; i++)
        vTaskDelay(pdMS_TO_TICKS(500));

      if (g_cap_done) {
        snprintf(self->captured_, sizeof(self->captured_), "%02X:%02X:%02X:%02X:%02X:%02X",
                 g_cap_bda[0], g_cap_bda[1], g_cap_bda[2], g_cap_bda[3], g_cap_bda[4],
                 g_cap_bda[5]);
        self->captured_pending_ = true;
        snprintf(self->pending_, sizeof(self->pending_), "captured %s", self->captured_);
      } else {
        snprintf(self->pending_, sizeof(self->pending_), "capture: nothing connected in 90s");
      }
      // Back to invisible. This device should not sit discoverable.
      esp_bt_gap_set_scan_mode(ESP_BT_NON_CONNECTABLE, ESP_BT_NON_DISCOVERABLE);
    }
  }

  self->result_pending_ = true;
  self->in_progress_ = false;
  vTaskDelete(nullptr);
}

void PS5Wake::wake_task_(void *arg) {
  auto *self = static_cast<PS5Wake *>(arg);
  const char *outcome = "page sent";

  if (!self->bt_up_(self->pad_)) {
    outcome = "bluetooth failed to start";
  } else {
    esp_err_t err = esp_bt_l2cap_init();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
      outcome = "l2cap_init failed";
    } else {
      // Still required: without vfs_register the connect below fails instantly with
      // ESP_BT_L2CAP_NO_RESOURCE and never reaches the radio, so no page goes out.
      err = esp_bt_l2cap_vfs_register();
      if (err != ESP_OK && err != ESP_ERR_INVALID_STATE)
        ESP_LOGW(TAG, "vfs_register failed: %s", esp_err_to_name(err));

      // ---- THE WAKE IS THE PAGE ----
      // Confirmed on hardware 2026-08-27: a powered-off PS5 turns ON when paged
      // from a BD_ADDR it recognises. No L2CAP channel is needed, no link key, no
      // HID reports. The console never accepts a channel and does not have to.
      // esp_bt_l2cap_connect is used purely as the page primitive, because
      // Bluedroid exposes no raw HCI CREATE_CONNECTION.
      //
      // The result is deliberately IGNORED. It always fails, and treating it as an
      // outcome inverted the diagnosis for hours — the previous version reported
      // "no l2cap open" on a successful wake.
      //
      // Retries are kept because they matter: a sleeping console only listens in
      // periodic page-scan windows, so pages spread over ~24s raise the chance of
      // overlapping one. This preserves the exact timing that worked.
      const uint16_t psms[2] = {0x11, 0x13};
      for (uint8_t attempt = 1; attempt <= self->retries_; attempt++) {
        for (uint16_t psm : psms) {
          err = esp_bt_l2cap_connect(ESP_BT_L2CAP_SEC_NONE, psm, self->ps5_);
          if (err != ESP_OK) {
            ESP_LOGW(TAG, "attempt %u psm 0x%02X page call failed: %s", attempt, psm,
                     esp_err_to_name(err));
            continue;
          }
          ESP_LOGD(TAG, "attempt %u paged psm 0x%02X", attempt, psm);
          vTaskDelay(pdMS_TO_TICKS(2000));
        }
        vTaskDelay(pdMS_TO_TICKS(300 * attempt));
      }
    }
  }

  if (self->bt_mode_ == BT_MODE_ON_DEMAND)
    self->bt_down_();

  // "page sent" means the pages went out, NOT that the console woke. There is no
  // ack to observe — the only reliable confirmation is the console itself.
  snprintf(self->pending_, sizeof(self->pending_), "%s (%u attempts) — check the console", outcome,
           self->retries_);
  self->result_pending_ = true;
  self->in_progress_ = false;
  vTaskDelete(nullptr);
}

}  // namespace ps5_wake
}  // namespace esphome
