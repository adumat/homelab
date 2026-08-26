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
volatile bool g_open_ok = false;
volatile bool g_open_done = false;
volatile int g_found = 0;

void gap_cb(esp_bt_gap_cb_event_t event, esp_bt_gap_cb_param_t *param) {
  if (event == ESP_BT_GAP_DISC_RES_EVT) {
    const uint8_t *b = param->disc_res.bda;
    char addr[18];
    snprintf(addr, sizeof(addr), "%02X:%02X:%02X:%02X:%02X:%02X", b[0], b[1], b[2], b[3], b[4], b[5]);
    char name[64] = "";
    int rssi = 0;
    for (int i = 0; i < param->disc_res.num_prop; i++) {
      const esp_bt_gap_dev_prop_t &p = param->disc_res.prop[i];
      if (p.type == ESP_BT_GAP_DEV_PROP_BDNAME && p.val != nullptr) {
        int n = p.len < static_cast<int>(sizeof(name)) - 1 ? p.len : static_cast<int>(sizeof(name)) - 1;
        memcpy(name, p.val, n);
        name[n] = '\0';
      } else if (p.type == ESP_BT_GAP_DEV_PROP_RSSI && p.val != nullptr) {
        rssi = *static_cast<int8_t *>(p.val);
      }
    }
    g_found = g_found + 1;
    // Deliberately ESP_LOGI, not D: this line IS the deliverable of a scan.
    ESP_LOGI("ps5_wake", "FOUND %s  rssi=%d  name='%s'", addr, rssi, name);
  } else if (event == ESP_BT_GAP_DISC_STATE_CHANGED_EVT) {
    ESP_LOGD("ps5_wake", "discovery state changed");
  }
}

void l2cap_cb(esp_bt_l2cap_cb_event_t event, esp_bt_l2cap_cb_param_t *param) {
  switch (event) {
    case ESP_BT_L2CAP_INIT_EVT:
      ESP_LOGD("ps5_wake", "l2cap init status=%d", param->init.status);
      break;
    case ESP_BT_L2CAP_CL_INIT_EVT:
      ESP_LOGD("ps5_wake", "l2cap client init status=%d", param->cl_init.status);
      break;
    case ESP_BT_L2CAP_OPEN_EVT:
      g_open_ok = (param->open.status == ESP_BT_L2CAP_SUCCESS);
      g_open_done = true;
      ESP_LOGI("ps5_wake", "l2cap open status=%d handle=%u", param->open.status,
               (unsigned) param->open.handle);
      break;
    case ESP_BT_L2CAP_CLOSE_EVT:
      ESP_LOGD("ps5_wake", "l2cap close status=%d", param->close.status);
      break;
    default:
      break;
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

  // Spoofing the pad's address MUST happen before controller init: the stack
  // reads the base MAC once, at init.
  esp_err_t err = esp_iface_mac_addr_set(pad_mac, ESP_MAC_BT);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "esp_iface_mac_addr_set failed: %s", esp_err_to_name(err));
    return false;
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
  ESP_LOGI(TAG, "bluedroid up, spoofing %02X:%02X:%02X:%02X:%02X:%02X", pad_mac[0], pad_mac[1],
           pad_mac[2], pad_mac[3], pad_mac[4], pad_mac[5]);
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
  if (this->result_pending_) {
    this->result_pending_ = false;
    this->publish_result_(this->pending_);
  }
}

void PS5Wake::scan() {
  if (this->in_progress_) {
    this->publish_result_("busy");
    return;
  }
  // bt_up_ needs a pad MAC because it spoofs before controller init. Spoofing
  // while scanning is harmless — we are only listening for inquiry responses.
  if (this->pad_mac_text_ == nullptr || !parse_mac_(this->pad_mac_text_->state, this->pad_)) {
    this->publish_result_("scan needs a valid pad_mac");
    return;
  }
  this->in_progress_ = true;
  this->publish_result_("scanning ~13s, watch the log");
  if (xTaskCreate(&PS5Wake::scan_task_, "ps5_scan", 6144, this, 5, nullptr) != pdPASS) {
    this->in_progress_ = false;
    this->publish_result_("could not start scan task");
  }
}

void PS5Wake::scan_task_(void *arg) {
  auto *self = static_cast<PS5Wake *>(arg);
  g_found = 0;

  if (!self->bt_up_(self->pad_)) {
    snprintf(self->pending_, sizeof(self->pending_), "scan: bluetooth failed to start");
  } else {
    esp_bt_gap_register_callback(gap_cb);
    // inq_len is in 1.28s units (0x01-0x30). 8 => ~10.2s of inquiry.
    esp_err_t err = esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 8, 0);
    if (err != ESP_OK) {
      ESP_LOGE(TAG, "start_discovery failed: %s", esp_err_to_name(err));
      snprintf(self->pending_, sizeof(self->pending_), "scan: start failed");
    } else {
      vTaskDelay(pdMS_TO_TICKS(13000));
      esp_bt_gap_cancel_discovery();
      snprintf(self->pending_, sizeof(self->pending_), "scan done: %d found (see log)",
               static_cast<int>(g_found));
    }
  }

  self->result_pending_ = true;
  self->in_progress_ = false;
  vTaskDelete(nullptr);
}

void PS5Wake::wake_task_(void *arg) {
  auto *self = static_cast<PS5Wake *>(arg);
  const char *outcome = "no l2cap open";

  if (!self->bt_up_(self->pad_)) {
    outcome = "bluetooth failed to start";
  } else {
    esp_bt_l2cap_register_callback(l2cap_cb);
    esp_err_t err = esp_bt_l2cap_init();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
      outcome = "l2cap_init failed";
    } else {
      // HID control (0x11) then HID interrupt (0x13). The console sees a trusted
      // controller reconnecting. No pairing needed: spoofing the pad's BD_ADDR
      // rides the bond the console already holds.
      const uint16_t psms[2] = {0x11, 0x13};
      bool ok = false;
      for (uint8_t attempt = 1; attempt <= self->retries_ && !ok; attempt++) {
        for (uint16_t psm : psms) {
          g_open_ok = false;
          g_open_done = false;
          err = esp_bt_l2cap_connect(0, psm, self->ps5_);
          if (err != ESP_OK) {
            ESP_LOGW(TAG, "attempt %u psm 0x%02X connect call failed: %s", attempt, psm,
                     esp_err_to_name(err));
            continue;
          }
          for (int i = 0; i < 40 && !g_open_done; i++)
            vTaskDelay(pdMS_TO_TICKS(50));
          if (g_open_done && g_open_ok) {
            ok = true;
            break;
          }
          ESP_LOGW(TAG, "attempt %u psm 0x%02X did not open", attempt, psm);
        }
        if (!ok)
          vTaskDelay(pdMS_TO_TICKS(300 * attempt));
      }
      outcome = ok ? "wake sent" : "no l2cap open";
    }
  }

  if (self->bt_mode_ == BT_MODE_ON_DEMAND)
    self->bt_down_();

  snprintf(self->pending_, sizeof(self->pending_), "%s (after %u attempts)", outcome,
           self->retries_);
  self->result_pending_ = true;
  self->in_progress_ = false;
  vTaskDelete(nullptr);
}

}  // namespace ps5_wake
}  // namespace esphome
