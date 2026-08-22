#pragma once

#include "esphome/core/component.h"
#include "esphome/core/automation.h"
#include "esphome/components/text/text.h"
#include "esphome/components/text_sensor/text_sensor.h"

#include <cstdint>
#include <string>

namespace esphome {
namespace ps5_wake {

enum BtMode : uint8_t {
  BT_MODE_ALWAYS_ON = 0,
  BT_MODE_ON_DEMAND = 1,
};

class PS5Wake : public Component {
 public:
  void setup() override;
  void dump_config() override;
  float get_setup_priority() const override { return setup_priority::AFTER_WIFI; }

  void set_pad_mac_text(text::Text *t) { this->pad_mac_text_ = t; }
  void set_ps5_mac_text(text::Text *t) { this->ps5_mac_text_ = t; }
  void set_last_result_sensor(text_sensor::TextSensor *s) { this->last_result_ = s; }
  void set_bt_mode(BtMode m) { this->bt_mode_ = m; }
  void set_retries(uint8_t r) { this->retries_ = r; }
  void set_min_heap_for_always_on(uint32_t h) { this->min_heap_ = h; }

  /// Run the wake sequence. Safe to call repeatedly; serialised internally.
  void wake();

 protected:
  /// Parse "AA:BB:CC:DD:EE:FF" into 6 bytes. Returns false on any malformed input.
  static bool parse_mac_(const std::string &in, uint8_t out[6]);

  /// Bring Bluedroid up with the pad's BD_ADDR spoofed. Idempotent.
  bool bt_up_(const uint8_t pad_mac[6]);
  /// Tear Bluedroid down. Only used in on_demand mode.
  void bt_down_();

  void publish_result_(const std::string &msg);

  text::Text *pad_mac_text_{nullptr};
  text::Text *ps5_mac_text_{nullptr};
  text_sensor::TextSensor *last_result_{nullptr};

  BtMode bt_mode_{BT_MODE_ALWAYS_ON};
  uint8_t retries_{5};
  uint32_t min_heap_{120000};

  bool bt_ready_{false};
  bool in_progress_{false};
};

template<typename... Ts> class WakeAction : public Action<Ts...> {
 public:
  explicit WakeAction(PS5Wake *parent) : parent_(parent) {}
  void play(Ts... x) override { this->parent_->wake(); }

 protected:
  PS5Wake *parent_;
};

}  // namespace ps5_wake
}  // namespace esphome
