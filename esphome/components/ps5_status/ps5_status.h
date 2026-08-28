#pragma once
#include "esphome/core/component.h"
#include "esphome/core/automation.h"
#include "esphome/core/helpers.h"
#include "esphome/components/text_sensor/text_sensor.h"
#include "ddp_parse.h"
#include <functional>
#include <string>

namespace esphome {
namespace ps5_status {

enum PS5State : uint8_t {
  PS5_ON = 0,
  PS5_REST = 1,
  PS5_SILENT = 2,   // no reply within the timeout, or sendto() failed
  PS5_UNKNOWN = 3,  // a reply arrived but did not parse
};

const char *ps5_state_to_string(PS5State st);

class PS5Status : public PollingComponent {
 public:
  void set_host(const std::string &host) { this->host_ = host; }
  void set_port(uint16_t port) { this->port_ = port; }
  void set_timeout(uint32_t timeout_ms) { this->timeout_ms_ = timeout_ms; }
  void set_state_sensor(text_sensor::TextSensor *s) { this->state_sensor_ = s; }

  void add_on_state_callback(std::function<void(std::string)> &&cb) {
    this->state_callback_.add(std::move(cb));
  }

  void setup() override;
  void update() override;
  void loop() override;
  void dump_config() override;
  float get_setup_priority() const override { return setup_priority::AFTER_WIFI; }

 protected:
  void resolve_(PS5State st);

  int sock_{-1};
  uint32_t addr_{0};
  std::string host_;
  uint16_t port_{9302};
  uint32_t timeout_ms_{2000};
  uint32_t sent_at_{0};
  bool awaiting_{false};
  text_sensor::TextSensor *state_sensor_{nullptr};
  CallbackManager<void(std::string)> state_callback_;
};

// One trigger instance per `on_state:` block. Each registers its own callback,
// because a Trigger holds exactly one parent Automation — sharing a single
// trigger across several blocks would silently drop all but the last.
class StateTrigger : public Trigger<std::string> {
 public:
  explicit StateTrigger(PS5Status *parent) {
    parent->add_on_state_callback([this](std::string state) { this->trigger(std::move(state)); });
  }
};

}  // namespace ps5_status
}  // namespace esphome
