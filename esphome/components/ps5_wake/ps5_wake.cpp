#include "ps5_wake.h"
#include "esphome/core/log.h"

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
  ESP_LOGCONFIG(TAG, "  bt_mode: %s", this->bt_mode_ == BT_MODE_ALWAYS_ON ? "always_on" : "on_demand");
  ESP_LOGCONFIG(TAG, "  retries: %u", this->retries_);
  ESP_LOGCONFIG(TAG, "  min_heap_for_always_on: %u", (unsigned) this->min_heap_);
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
  this->publish_result_("MACs parsed; BT not implemented yet");
}

}  // namespace ps5_wake
}  // namespace esphome
