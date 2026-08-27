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

  /// Kick off the wake sequence. Returns immediately — the work happens on a
  /// separate task, because it blocks for seconds and the ESPHome loop must not.
  void wake();

  /// Publishes any result the worker task left behind. Runs on the main loop.
  void loop() override;


  /// Become discoverable so the PS5 can find us on its Bluetooth Accessories
  /// screen. When the console opens a link we capture its address and write it
  /// into ps5_mac. The pairing itself is expected to FAIL and that is fine — the
  /// address arrives with the ACL connection, before any pairing outcome.
  void capture();

 protected:
  /// The blocking wake sequence. Runs on its own FreeRTOS task, NEVER the loop.
  static void wake_task_(void *arg);
  /// Discoverable-and-wait, so the console connects to us. Own task, same reason.
  static void capture_task_(void *arg);
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
  volatile bool in_progress_{false};

  /// MACs are snapshotted here before the task starts, so the task never touches
  /// the text entities — those belong to the main loop.
  uint8_t pad_[6]{};
  uint8_t ps5_[6]{};

  /// Result handoff from the worker task to the main loop. ESPHome components are
  /// NOT thread-safe, so the task must not call publish_state() itself; it writes
  /// here and loop() does the publishing.
  volatile bool result_pending_{false};
  char pending_[64]{};

  /// Address captured in capture mode, handed to the main loop to write into the
  /// ps5_mac text entity — the task must not touch entities itself.
  volatile bool captured_pending_{false};
  char captured_[18]{};
};

template<typename... Ts> class WakeAction : public Action<Ts...> {
 public:
  explicit WakeAction(PS5Wake *parent) : parent_(parent) {}
  void play(Ts... x) override { this->parent_->wake(); }

 protected:
  PS5Wake *parent_;
};

template<typename... Ts> class CaptureAction : public Action<Ts...> {
 public:
  explicit CaptureAction(PS5Wake *parent) : parent_(parent) {}
  void play(Ts... x) override { this->parent_->capture(); }

 protected:
  PS5Wake *parent_;
};

}  // namespace ps5_wake
}  // namespace esphome
