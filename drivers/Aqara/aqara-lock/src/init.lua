local security = require "st.security"
local ZigbeeDriver = require "st.zigbee"
local data_types = require "st.zigbee.data_types"
local cluster_base = require "st.zigbee.cluster_base"
local capabilities = require "st.capabilities"
local base64 = require "base64"
local credential_utils = require "credential_utils"
local utils = require "st.utils"

local remoteControlStatus = capabilities.remoteControlStatus
local lockCredentialInfo = capabilities["stse.lockCredentialInfo"]
local antiLockStatus = capabilities["stse.antiLockStatus"]
local Battery = capabilities.battery
local Lock = capabilities.lock
local LockAlarm = capabilities.lockAlarm

local PRI_CLU = 0xFCC0
local PRI_ATTR = 0xFFF3
local MFG_CODE = 0x115F

local SHARED_KEY = "__shared_key"
local CLOUD_PUBLIC_KEY = "__cloud_public_key"
local SUPPORTED_ALARM_VALUES = { "damaged", "forcedOpeningAttempt", "unableToLockTheDoor", "notClosedForALongTime",
  "highTemperature", "attemptsExceeded" }
local SERIAL_NUM_TX = "serial_num_tx"
local SERIAL_NUM_RX = "serial_num_rx"
local SEQ_NUM = "seq_num"

local function my_secret_data_handler(driver, device, secret_info)
  if secret_info.secret_kind ~= "aqara" then return end

  local shared_key = secret_info.shared_key
  local cloud_public_key = secret_info.cloud_public_key

  device:set_field(SHARED_KEY, shared_key, { persist = true })
  device:set_field(CLOUD_PUBLIC_KEY, cloud_public_key, { persist = true })
  credential_utils.save_data(driver)

  if cloud_public_key ~= nil then
    local raw_data = base64.decode(cloud_public_key)
    -- send cloud_pub_key
    device:send(cluster_base.write_manufacturer_specific_attribute(device,
      PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, "\x3E" .. raw_data))
  end
end

local function remoteControlShow(device)
  if credential_utils.is_exist_host(device) then
    device:emit_event(remoteControlStatus.remoteControlEnabled('true', { visibility = { displayed = false } }))
  else
    credential_utils.set_host_count(device, 0)
    device:emit_event(remoteControlStatus.remoteControlEnabled('false', { visibility = { displayed = false } }))
  end
end

local function comp_supported_alarm_values(last_alarm_values)
  if not last_alarm_values then return false end
  if #last_alarm_values ~= #SUPPORTED_ALARM_VALUES then return false end
  for k, v in pairs(last_alarm_values) do
    if SUPPORTED_ALARM_VALUES[k] ~= v then return false end
  end
  return true
end

local function device_init(self, device)
  device:set_field(SERIAL_NUM_RX, 0)
  device:set_field(SERIAL_NUM_TX, 1)
  device:set_field(SEQ_NUM, 0)
  local last_alarm_values = device:get_latest_state("main", LockAlarm.ID, LockAlarm.supportedAlarmValues.NAME) or {}
  if not comp_supported_alarm_values(last_alarm_values) then
    device:emit_event(
      LockAlarm.supportedAlarmValues(SUPPORTED_ALARM_VALUES, { visibility = { displayed = false } })
    )
  end
  device:emit_event(capabilities.lock.supportedUnlockDirections({ "fromInside", "fromOutside" },
    { visibility = { displayed = false } }))
  device:emit_event(capabilities.battery.type("AA"))
  local battery_quantity = 8
  if device:get_model() == "aqara.lock.akr001" then
    battery_quantity = 6
  end
  device:emit_event(capabilities.battery.quantity(battery_quantity))
end

local function device_added(self, device)
  remoteControlShow(device)
  device:emit_event(Battery.battery(100))
  device:emit_event(LockAlarm.alarm.clear({ visibility = { displayed = false } }))
  device:emit_event(antiLockStatus.antiLockStatus("unknown", { visibility = { displayed = false } }))
  device:emit_event(Lock.lock.locked())
  credential_utils.save_data(self)
end

local function toValue(payload, start, length)
  return utils.deserialize_int(string.sub(payload, start, start + length - 1), length, false, false)
end

local function toHex(value, length)
  return utils.serialize_int(value, length, false, false)
end

local METHOD = {
  LOCKED = "locked",
  MANUAL = "manual",
  FINGERPRINT = "fingerprint",
  KEYPAD = "keypad",
  RFID = "rfid",
  RF447 = "rf447",
  BLUETOOTH = "bluetooth",
  COMMAND = "command",
  NO_USE = ""
}

local function event_lock_handler(driver, device, evt_name, evt_value)
  if evt_value == 0x1 then
    device:emit_event(Lock.lock(evt_name))
    device:emit_event(LockAlarm.alarm.clear({ visibility = { displayed = false } }))
    remoteControlShow(device)
  end
end

local function event_unlock_indoor_handler(driver, device, evt_name, evt_value)
  device:emit_event(Lock.lock.unlocked({ data = { method = evt_name, codeId = nil, codeName = nil, unlockDirection = "fromInside" } }))
  device:emit_event(remoteControlStatus.remoteControlEnabled('false', { visibility = { displayed = false } }))
  device:emit_event(LockAlarm.alarm.clear({ visibility = { displayed = false } }))
end

local function event_unlock_outdoor_handler(driver, device, evt_name, evt_value)
  local id, label = credential_utils.find_userLabel(driver, device, evt_value)
  device:emit_event(Lock.lock.unlocked({ data = { method = evt_name, codeId = id, codeName = label, unlockDirection = "fromOutside" } }))
  device:emit_event(remoteControlStatus.remoteControlEnabled('false', { visibility = { displayed = false } }))
  device:emit_event(LockAlarm.alarm.clear({ visibility = { displayed = false } }))
end

local function event_unlock_rf447_handler(driver, device, evt_name, evt_value)
  device:emit_event(Lock.lock.unlocked({ data = { method = evt_name, codeId = nil, codeName = nil, unlockDirection = nil } }))
  device:emit_event(remoteControlStatus.remoteControlEnabled('false', { visibility = { displayed = false } }))
  device:emit_event(LockAlarm.alarm.clear({ visibility = { displayed = false } }))
end

local function event_unlock_remote_handler(driver, device, evt_name, evt_value)
  device:emit_event(Lock.lock.unlocked({ data = { method = evt_name, codeId = nil, codeName = nil, unlockDirection = nil } }))
  device:emit_event(remoteControlStatus.remoteControlEnabled('false', { visibility = { displayed = false } }))
  device:emit_event(LockAlarm.alarm.clear({ visibility = { displayed = false } }))
end

local function event_unlock_otp_handler(driver, device, evt_name, evt_value)
  device:emit_event(Lock.lock.unlocked({ data = { method = evt_name, codeId = "OTP_STANDALONE", codeName = nil, unlockDirection = "fromOutside" } }))
  device:emit_event(remoteControlStatus.remoteControlEnabled('false', { visibility = { displayed = false } }))
  device:emit_event(LockAlarm.alarm.clear({ visibility = { displayed = false } }))
end

local function event_door_handler(driver, device, evt_name, evt_value)
  if evt_value == 0x2 then
    device:emit_event(LockAlarm.alarm.notClosedForALongTime())
  elseif evt_value == 0x4 then
    device:emit_event(LockAlarm.alarm.forcedOpeningAttempt())
  end
end

local function event_battery_handler(driver, device, evt_name, evt_value)
  device:emit_event(Battery.battery(evt_value))
end

local function event_abnormal_status_handler(driver, device, evt_name, evt_value)
  if evt_value == 0xC0DE1006 then
    device:emit_event(LockAlarm.alarm.highTemperature())
  elseif evt_value == 0xC0DE000A then
    device:emit_event(LockAlarm.alarm.attemptsExceeded({ state_change = true }))
  end
end

local function event_anti_lock_handler(driver, device, evt_name, evt_value)
  local evt = "disabled"
  if evt_value == 0x1 then evt = "enabled" end
  device:emit_event(antiLockStatus.antiLockStatus(evt))
end
local function event_lock_status_handler(driver, device, evt_name, evt_value)
  if evt_value == 0x1 then
    device:emit_event(LockAlarm.alarm.unableToLockTheDoor())
  elseif evt_value == 0xA then
    device:emit_event(LockAlarm.alarm.damaged())
  end
end

local resource_id = {
  ["13.31.85"] = { event_name = METHOD.LOCKED, event_handler = event_lock_handler },
  ["13.48.85"] = { event_name = METHOD.MANUAL, event_handler = event_unlock_indoor_handler },
  ["13.51.85"] = { event_name = METHOD.MANUAL, event_handler = event_unlock_indoor_handler },
  ["13.42.85"] = { event_name = METHOD.FINGERPRINT, event_handler = event_unlock_outdoor_handler },
  ["13.43.85"] = { event_name = METHOD.KEYPAD, event_handler = event_unlock_outdoor_handler },
  ["13.44.85"] = { event_name = METHOD.RFID, event_handler = event_unlock_outdoor_handler },
  ["13.151.85"] = { event_name = METHOD.RF447, event_handler = event_unlock_rf447_handler },
  ["13.45.85"] = { event_name = METHOD.BLUETOOTH, event_handler = event_unlock_remote_handler },
  ["13.90.85"] = { event_name = METHOD.COMMAND, event_handler = event_unlock_remote_handler },
  ["13.46.85"] = { event_name = METHOD.KEYPAD, event_handler = event_unlock_otp_handler },
  ["13.17.85"] = { event_name = METHOD.NO_USE, event_handler = event_door_handler },
  ["13.56.85"] = { event_name = METHOD.NO_USE, event_handler = event_battery_handler },
  ["13.32.85"] = { event_name = METHOD.NO_USE, event_handler = event_abnormal_status_handler },
  ["13.33.85"] = { event_name = METHOD.NO_USE, event_handler = event_anti_lock_handler },
  ["13.88.85"] = { event_name = METHOD.NO_USE, event_handler = event_lock_status_handler }
}

local function request_generate_shared_key(device)
  device:send(cluster_base.write_manufacturer_specific_attribute(device,
    PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, "\x2B"))
end

local function lock_state_handler(driver, device, value, zb_rx)
  local shared_key = device:get_field(SHARED_KEY)
  local param = value.value
  local command = string.sub(param, 0, 1)

  if command == "\x3E" then
    -- recv lock_pub_key
    local locks_pub_key = string.sub(param, 2, string.len(param))
    local mn_id = "Id3A"
    local setup_id = "006"
    local product_id = ""
    local res, _ = security.get_aqara_secret(device.zigbee_eui, locks_pub_key, "", mn_id, setup_id,
      product_id)
    if res then
      print(res)
    end
    device:set_field(SERIAL_NUM_RX, 0)
    device:set_field(SERIAL_NUM_TX, 1)
  elseif shared_key == nil then
    request_generate_shared_key(device)
  elseif command == "\x93" then
    local opts = { cipher = "aes256-ecb", padding = false }
    local raw_key = base64.decode(shared_key)
    local raw_data = string.sub(param, 2, string.len(param))
    local msg = security.decrypt_bytes(raw_data, raw_key, opts)
    local text = string.sub(msg, 5, string.len(msg))
    local payload = string.sub(text, 4, string.len(text))
    local func_id = toValue(payload, 1, 1) .. "." .. toValue(payload, 2, 1) .. "." .. toValue(payload, 3, 2)
    local serial_num = toValue(msg, 3, 2)
    local last_serial_num = device:get_field(SERIAL_NUM_RX) or 0

    if serial_num > last_serial_num then
      device:set_field(SERIAL_NUM_RX, serial_num)
      if resource_id[func_id] then
        resource_id[func_id].event_handler(driver, device, resource_id[func_id].event_name,
          toValue(payload, 6, string.byte(payload, 5)))
      end
    else
      request_generate_shared_key(device)
    end
  end
end

local function send_msg(device, funcA, funcB, funcC, op_code, length, value)
  local shared_key = device:get_field(SHARED_KEY)
  if shared_key == nil then
    request_generate_shared_key(device)
  else
    local seq_num = device:get_field(SEQ_NUM) or 0
    local serial_num = device:get_field(SERIAL_NUM_TX) or 1

    local payload = toHex(funcA, 1) .. toHex(funcB, 1) .. toHex(funcC, 2) .. toHex(length, 1) .. toHex(value, length)
    local text = "\x00" .. toHex(op_code, 1) .. toHex(seq_num, 1) .. payload
    local raw_data = "\x5B" .. toHex(string.len(text), 1) .. toHex(serial_num, 2) .. text
    for i = 1, 4 - (string.len(raw_data) % 4) do
      raw_data = raw_data .. "\x00"
    end

    local opts = { cipher = "aes256-ecb", padding = false }
    local raw_key = base64.decode(shared_key)

    if raw_key ~= nil then
      local result = security.encrypt_bytes(raw_data, raw_key, opts)
      if result ~= nil then
        local msg = "\x93" .. result
        device:send(cluster_base.write_manufacturer_specific_attribute(device,
          PRI_CLU, PRI_ATTR, MFG_CODE, data_types.OctetString, msg))
        if seq_num == 0xFF then
          device:set_field(SEQ_NUM, 0)
        else
          device:set_field(SEQ_NUM, seq_num + 1)
        end
        if serial_num == 0xFFFF then
          request_generate_shared_key(device)
        else
          device:set_field(SERIAL_NUM_TX, serial_num + 1)
        end
      end
    end
  end
end

local function unlock_cmd_handler(driver, device, cmd)
  send_msg(device, 4, 17, 85, 2, 1, 1)
end

local aqara_locks_handler = {
  NAME = "Aqara Doorlock K100",
  supported_capabilities = {
    Lock,
    LockAlarm,
    Battery,
    lockCredentialInfo,
    capabilities.refresh,
  },
  zigbee_handlers = {
    attr = {
      [PRI_CLU] = {
        [PRI_ATTR] = lock_state_handler
      }
    }
  },
  capability_handlers = {
    [lockCredentialInfo.ID] = {
      [lockCredentialInfo.commands.syncAll.NAME] = credential_utils.sync_all_credential_info,
      [lockCredentialInfo.commands.upsert.NAME] = credential_utils.upsert_credential_info,
      [lockCredentialInfo.commands.deleteUser.NAME] = credential_utils.delete_user,
      [lockCredentialInfo.commands.deleteCredential.NAME] = credential_utils.delete_credential
    },
    [capabilities.lock.ID] = {
      [capabilities.lock.commands.unlock.NAME] = unlock_cmd_handler
    }
  },
  lifecycle_handlers = {
    init = device_init,
    added = device_added
  },
  secret_data_handlers = {
    [security.SECRET_KIND_AQARA] = my_secret_data_handler
  }
}

local aqara_locks_driver = ZigbeeDriver("aqara_locks_k100", aqara_locks_handler)
aqara_locks_driver:run()
