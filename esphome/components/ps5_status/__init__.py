import esphome.codegen as cg
import esphome.config_validation as cv
from esphome import automation
from esphome.components import text_sensor
from esphome.const import CONF_ID, CONF_PORT, CONF_TIMEOUT, CONF_TRIGGER_ID

CODEOWNERS = ["@adumat"]
DEPENDENCIES = ["wifi"]
AUTO_LOAD = ["text_sensor"]

CONF_HOST = "host"
CONF_STATE = "state"
CONF_ON_STATE = "on_state"

ps5_status_ns = cg.esphome_ns.namespace("ps5_status")
PS5Status = ps5_status_ns.class_("PS5Status", cg.PollingComponent)
StateTrigger = ps5_status_ns.class_(
    "StateTrigger", automation.Trigger.template(cg.std_string)
)

CONFIG_SCHEMA = cv.Schema(
    {
        cv.GenerateID(): cv.declare_id(PS5Status),
        # Validated as an IPv4 literal on purpose: a typo must fail the build,
        # not silently read as "the console is off".
        cv.Required(CONF_HOST): cv.ipv4address,
        cv.Optional(CONF_PORT, default=9302): cv.port,
        cv.Optional(CONF_TIMEOUT, default="2s"): cv.positive_time_period_milliseconds,
        cv.Optional(CONF_STATE): text_sensor.text_sensor_schema(),
        cv.Optional(CONF_ON_STATE): automation.validate_automation(
            {cv.GenerateID(CONF_TRIGGER_ID): cv.declare_id(StateTrigger)}
        ),
    }
).extend(cv.polling_component_schema("60s"))


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)

    cg.add(var.set_host(str(config[CONF_HOST])))
    cg.add(var.set_port(config[CONF_PORT]))
    cg.add(var.set_timeout(config[CONF_TIMEOUT]))

    if CONF_STATE in config:
        sens = await text_sensor.new_text_sensor(config[CONF_STATE])
        cg.add(var.set_state_sensor(sens))

    for conf in config.get(CONF_ON_STATE, []):
        trigger = cg.new_Pvariable(conf[CONF_TRIGGER_ID], var)
        await automation.build_automation(trigger, [(cg.std_string, "x")], conf)
