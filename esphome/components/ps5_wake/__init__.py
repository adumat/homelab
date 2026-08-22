import esphome.codegen as cg
import esphome.config_validation as cv
from esphome import automation
from esphome.components import text, text_sensor
from esphome.const import CONF_ID

CODEOWNERS = ["@adumat"]
DEPENDENCIES = ["esp32"]

CONF_PAD_MAC = "pad_mac"
CONF_PS5_MAC = "ps5_mac"
CONF_BT_MODE = "bt_mode"
CONF_RETRIES = "retries"
CONF_MIN_HEAP_FOR_ALWAYS_ON = "min_heap_for_always_on"
CONF_LAST_RESULT = "last_result"

ps5_wake_ns = cg.esphome_ns.namespace("ps5_wake")
PS5Wake = ps5_wake_ns.class_("PS5Wake", cg.Component)
BtMode = ps5_wake_ns.enum("BtMode")

BT_MODES = {
    "always_on": BtMode.BT_MODE_ALWAYS_ON,
    "on_demand": BtMode.BT_MODE_ON_DEMAND,
}

WakeAction = ps5_wake_ns.class_("WakeAction", automation.Action)

CONFIG_SCHEMA = cv.Schema(
    {
        cv.GenerateID(): cv.declare_id(PS5Wake),
        cv.Required(CONF_PAD_MAC): cv.use_id(text.Text),
        cv.Required(CONF_PS5_MAC): cv.use_id(text.Text),
        cv.Optional(CONF_BT_MODE, default="always_on"): cv.enum(BT_MODES, lower=True),
        cv.Optional(CONF_RETRIES, default=5): cv.int_range(min=1, max=10),
        cv.Optional(CONF_MIN_HEAP_FOR_ALWAYS_ON, default=120000): cv.positive_int,
        cv.Optional(CONF_LAST_RESULT): cv.use_id(text_sensor.TextSensor),
    }
).extend(cv.COMPONENT_SCHEMA)


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)

    pad = await cg.get_variable(config[CONF_PAD_MAC])
    ps5 = await cg.get_variable(config[CONF_PS5_MAC])
    cg.add(var.set_pad_mac_text(pad))
    cg.add(var.set_ps5_mac_text(ps5))

    cg.add(var.set_bt_mode(config[CONF_BT_MODE]))
    cg.add(var.set_retries(config[CONF_RETRIES]))
    cg.add(var.set_min_heap_for_always_on(config[CONF_MIN_HEAP_FOR_ALWAYS_ON]))

    if CONF_LAST_RESULT in config:
        last = await cg.get_variable(config[CONF_LAST_RESULT])
        cg.add(var.set_last_result_sensor(last))


@automation.register_action(
    "ps5_wake.wake",
    WakeAction,
    automation.maybe_simple_id(
        cv.Schema({cv.GenerateID(): cv.use_id(PS5Wake)})
    ),
)
async def wake_action_to_code(config, action_id, template_arg, args):
    parent = await cg.get_variable(config[CONF_ID])
    return cg.new_Pvariable(action_id, template_arg, parent)
