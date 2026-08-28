#pragma once
// Pure DDP status-line parsing. Deliberately free of ESPHome includes so it can
// be compiled and tested on a host with plain g++.
#include <cstddef>
#include <cstdint>

namespace ps5 {

enum DdpStatus : uint8_t {
  DDP_ON = 0,       // HTTP/1.1 200 — console awake
  DDP_REST = 1,     // HTTP/1.1 620 — rest mode, network alive
  DDP_UNKNOWN = 2,  // unparseable, truncated, binary junk, or an unexpected code
};

// Returns DDP_UNKNOWN for anything that is not a recognised status line. A
// resting console emits malformed datagrams — one was observed at an ON->REST
// transition on 2026-08-27 — and those must never be mistaken for a state
// change, because the keepalive policy would read it as the console going away.
inline DdpStatus parse_ddp_status(const char *buf, size_t len) {
  static const char PREFIX[] = "HTTP/1.1 ";
  const size_t plen = sizeof(PREFIX) - 1;  // 9
  if (buf == nullptr || len < plen + 3)
    return DDP_UNKNOWN;
  for (size_t i = 0; i < plen; i++)
    if (buf[i] != PREFIX[i])
      return DDP_UNKNOWN;
  const char *c = buf + plen;
  for (size_t i = 0; i < 3; i++)
    if (c[i] < '0' || c[i] > '9')
      return DDP_UNKNOWN;
  const int code = (c[0] - '0') * 100 + (c[1] - '0') * 10 + (c[2] - '0');
  switch (code) {
    case 200:
      return DDP_ON;
    case 620:
      return DDP_REST;
    default:
      return DDP_UNKNOWN;
  }
}

}  // namespace ps5
