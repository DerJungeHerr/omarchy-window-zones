// A wlr virtual pointer driven from stdin, for the end-to-end tests.
//   move <dx> <dy>   relative motion
//   down / up        left button
// The protocol interfaces are declared here, so no generated code is needed.
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include <linux/input-event-codes.h>

static const struct wl_interface pointer_iface;
static const struct wl_interface *create_types[] = { &wl_seat_interface, &pointer_iface };
static const struct wl_message manager_requests[] = {
  { "create_virtual_pointer", "?on", create_types },
};
static const struct wl_interface manager_iface = {
  "zwlr_virtual_pointer_manager_v1", 1, 1, manager_requests, 0, NULL,
};
static const struct wl_interface *no_types[8];
static const struct wl_message pointer_requests[] = {
  { "motion", "uff", no_types },
  { "motion_absolute", "uuuuu", no_types },
  { "button", "uuu", no_types },
  { "axis", "uuf", no_types },
  { "frame", "", no_types },
};
static const struct wl_interface pointer_iface = {
  "zwlr_virtual_pointer_v1", 1, 5, pointer_requests, 0, NULL,
};

static struct wl_proxy *manager;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *iface, uint32_t version) {
  (void)data; (void)version;
  if (!strcmp(iface, manager_iface.name)) manager = wl_registry_bind(registry, name, &manager_iface, 1);
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
  (void)data; (void)registry; (void)name;
}

static uint32_t now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

int main(void) {
  struct wl_display *display = wl_display_connect(NULL);
  if (!display) return 1;
  struct wl_registry *registry = wl_display_get_registry(display);
  static const struct wl_registry_listener listener = { global, global_remove };
  wl_registry_add_listener(registry, &listener, NULL);
  wl_display_roundtrip(display);
  if (!manager) return 2;

  struct wl_proxy *pointer = wl_proxy_marshal_flags(manager, 0, &pointer_iface, 1, 0, NULL, NULL);
  char line[128];
  while (fgets(line, sizeof line, stdin)) {
    double dx, dy;
    if (sscanf(line, "move %lf %lf", &dx, &dy) == 2)
      wl_proxy_marshal_flags(pointer, 0, NULL, 1, 0, now_ms(), wl_fixed_from_double(dx), wl_fixed_from_double(dy));
    else if (!strncmp(line, "down", 4) || !strncmp(line, "up", 2))
      wl_proxy_marshal_flags(pointer, 2, NULL, 1, 0, now_ms(), BTN_LEFT, line[0] == 'd' ? 1 : 0);
    else
      continue;
    wl_proxy_marshal_flags(pointer, 4, NULL, 1, 0);
    wl_display_flush(display);
  }
  wl_display_roundtrip(display);
  return 0;
}
