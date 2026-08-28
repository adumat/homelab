#include "ps5_status.h"
#include "esphome/core/log.h"
#include "esphome/core/hal.h"

#include <lwip/sockets.h>
#include <lwip/inet.h>
#include <fcntl.h>
#include <cerrno>

namespace esphome {
namespace ps5_status {

static const char *const TAG = "ps5_status";

// The DDP discovery request. \n line endings with a trailing \n, as the console
// expects. Verified against a real PS5 on 2026-08-27.
static const char SRCH[] = "SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n";

const char *ps5_state_to_string(PS5State st) {
  switch (st) {
    case PS5_ON:
      return "on";
    case PS5_REST:
      return "rest";
    case PS5_SILENT:
      return "silent";
    default:
      return "unknown";
  }
}

void PS5Status::setup() {
  this->addr_ = ::inet_addr(this->host_.c_str());
  if (this->addr_ == INADDR_NONE) {
    // Deliberately fatal. A bad host would otherwise report "silent" forever,
    // which the keepalive policy reads as "console is off" — so it would page
    // the console over and over with no possibility of success.
    ESP_LOGE(TAG, "invalid host '%s' — component disabled", this->host_.c_str());
    this->mark_failed();
    return;
  }
  this->sock_ = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (this->sock_ < 0) {
    ESP_LOGE(TAG, "socket() failed, errno %d", errno);
    this->mark_failed();
    return;
  }
  const int flags = ::fcntl(this->sock_, F_GETFL, 0);
  ::fcntl(this->sock_, F_SETFL, flags | O_NONBLOCK);
  ESP_LOGI(TAG, "probing %s:%u every %ums, timeout %ums", this->host_.c_str(), this->port_,
           this->get_update_interval(), this->timeout_ms_);
}

void PS5Status::dump_config() {
  ESP_LOGCONFIG(TAG, "ps5_status: %s:%u timeout %ums", this->host_.c_str(), this->port_,
                this->timeout_ms_);
}

void PS5Status::update() {
  if (this->sock_ < 0)
    return;
  // A cycle that never got an answer resolves here rather than being dropped,
  // so exactly one observation is emitted per poll interval.
  if (this->awaiting_)
    this->resolve_(PS5_SILENT);

  struct sockaddr_in dst {};
  dst.sin_family = AF_INET;
  dst.sin_port = htons(this->port_);
  dst.sin_addr.s_addr = this->addr_;
  const ssize_t n =
      ::sendto(this->sock_, SRCH, sizeof(SRCH) - 1, 0, (struct sockaddr *) &dst, sizeof(dst));
  if (n < 0) {
    // ENETUNREACH / EHOSTDOWN: an off console, or our own link is down. Both are
    // "no answer" — the policy decides what that means.
    ESP_LOGD(TAG, "sendto failed, errno %d", errno);
    this->resolve_(PS5_SILENT);
    return;
  }
  this->awaiting_ = true;
  this->sent_at_ = millis();
}

void PS5Status::loop() {
  if (!this->awaiting_ || this->sock_ < 0)
    return;
  char buf[256];
  const ssize_t n = ::recvfrom(this->sock_, buf, sizeof(buf), MSG_DONTWAIT, nullptr, nullptr);
  if (n > 0) {
    switch (ps5::parse_ddp_status(buf, (size_t) n)) {
      case ps5::DDP_ON:
        this->resolve_(PS5_ON);
        break;
      case ps5::DDP_REST:
        this->resolve_(PS5_REST);
        break;
      default:
        this->resolve_(PS5_UNKNOWN);
        break;
    }
    return;
  }
  // Subtraction, not `millis() < deadline`: millis() wraps at 49.7 days and this
  // device is meant to run for months.
  if ((int32_t) (millis() - (this->sent_at_ + this->timeout_ms_)) >= 0)
    this->resolve_(PS5_SILENT);
}

void PS5Status::resolve_(PS5State st) {
  this->awaiting_ = false;
  const char *s = ps5_state_to_string(st);
  ESP_LOGD(TAG, "observation: %s", s);
  if (this->state_sensor_ != nullptr)
    this->state_sensor_->publish_state(s);
  this->state_callback_.call(std::string(s));
}

}  // namespace ps5_status
}  // namespace esphome
