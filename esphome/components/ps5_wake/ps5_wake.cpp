#include "ps5_wake.h"
#include "esphome/core/log.h"

namespace esphome {
namespace ps5_wake {

static const char *const TAG = "ps5_wake";

void PS5Wake::setup() { ESP_LOGCONFIG(TAG, "ps5_wake scaffold up"); }

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
bool PS5Wake::bt_up_(const uint8_t pad_mac[6]) { return false; }
void PS5Wake::bt_down_() {}

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
