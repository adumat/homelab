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
  if (this->in_progress_) {
    this->publish_result_("wake already in progress");
    return;
  }
  if (this->pad_mac_text_ == nullptr || this->ps5_mac_text_ == nullptr) {
    this->publish_result_("no MAC entities bound");
    return;
  }

  uint8_t pad[6];
  uint8_t ps5[6];
  if (!parse_mac_(this->pad_mac_text_->state, pad)) {
    this->publish_result_("pad_mac is not a valid MAC");
    return;
  }
  if (!parse_mac_(this->ps5_mac_text_->state, ps5)) {
    this->publish_result_("ps5_mac is not a valid MAC");
    return;
  }

  this->in_progress_ = true;

  if (!this->bt_up_(pad)) {
    this->publish_result_("bluetooth failed to start");
    this->in_progress_ = false;
    return;
  }

  esp_bt_l2cap_register_callback(l2cap_cb);
  esp_err_t err = esp_bt_l2cap_init();
  if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
    this->publish_result_("l2cap_init failed");
    this->in_progress_ = false;
    return;
  }

  // HID control (0x11) then HID interrupt (0x13). The console sees a trusted
  // controller reconnecting and wakes. No pairing is needed: spoofing the pad's
  // BD_ADDR rides the bond the console already holds.
  const uint16_t psms[2] = {0x11, 0x13};
  bool ok = false;

  for (uint8_t attempt = 1; attempt <= this->retries_ && !ok; attempt++) {
    for (uint16_t psm : psms) {
      g_open_ok = false;
      g_open_done = false;
      err = esp_bt_l2cap_connect(0, psm, ps5);
      if (err != ESP_OK) {
        ESP_LOGW(TAG, "attempt %u psm 0x%02X connect call failed: %s", attempt, psm,
                 esp_err_to_name(err));
        continue;
      }
      // Wait for the callback rather than assuming success.
      for (int i = 0; i < 40 && !g_open_done; i++)
        vTaskDelay(pdMS_TO_TICKS(50));
      if (g_open_done && g_open_ok) {
        ok = true;
        break;
      }
      ESP_LOGW(TAG, "attempt %u psm 0x%02X did not open", attempt, psm);
    }
    if (!ok)
      vTaskDelay(pdMS_TO_TICKS(300 * attempt));  // backoff
  }

  if (ok) {
    this->publish_result_("wake sent");
  } else {
    char buf[48];
    snprintf(buf, sizeof(buf), "no l2cap open after %u attempts", this->retries_);
    this->publish_result_(buf);
  }

  if (this->bt_mode_ == BT_MODE_ON_DEMAND)
    this->bt_down_();

  this->in_progress_ = false;
}

}  // namespace ps5_wake
}  // namespace esphome
