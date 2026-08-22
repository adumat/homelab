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

bool PS5Wake::parse_mac_(const std::string &in, uint8_t out[6]) { return false; }
bool PS5Wake::bt_up_(const uint8_t pad_mac[6]) { return false; }
void PS5Wake::bt_down_() {}

void PS5Wake::wake() { this->publish_result_("not implemented yet"); }

}  // namespace ps5_wake
}  // namespace esphome
