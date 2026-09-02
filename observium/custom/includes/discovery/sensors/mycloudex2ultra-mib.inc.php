<?php
/**
 * WD My Cloud EX2 Ultra temperature sensors.
 *
 * WD exposes chassis and disk temperatures as DisplayString values like
 * "Centigrade:50" (chassis also appends Fahrenheit). Observium's generic
 * numeric SNMP poller cannot graph those unless snmp_fix_numeric is taught
 * to extract the Centigrade figure — that patch is applied at container
 * start by observium/custom/install-into-container.sh.
 *
 * This module is a no-op on Linux hosts that do not answer the WD enterprise
 * tree, so NAS2 can stay classified as Linux.
 */

if (defined('HOMEOPS_MYCLOUDEX2ULTRA_LOADED')) {
    return;
}
define('HOMEOPS_MYCLOUDEX2ULTRA_LOADED', true);

if (!isset($device) || empty($device['device_id']) || !function_exists('snmp_get')) {
    return;
}

if (!function_exists('homeops_wd_parse_centigrade')) {
    function homeops_wd_parse_centigrade($raw)
    {
        if ($raw === false || $raw === '' || $raw === 'U') {
            return false;
        }
        $raw = trim($raw, " \t\n\r\0\x0B\"");
        if (preg_match('/No Such/i', $raw)) {
            return false;
        }
        if (preg_match('/Centigrade:\s*(-?\d+(?:\.\d+)?)/i', $raw, $m)) {
            return $m[1] + 0;
        }
        if (is_numeric($raw)) {
            return $raw + 0;
        }
        return false;
    }
}

if (!function_exists('homeops_wd_snmp_get')) {
    function homeops_wd_snmp_get($device, $oid)
    {
        $raw = @snmp_get($device, $oid, '-OQv');
        if ($raw === false || $raw === '') {
            $raw = @snmp_get($device, $oid, '-Oqv');
        }
        if (is_string($raw)) {
            $raw = trim($raw, " \t\n\r\0\x0B\"");
        }
        return $raw;
    }
}

if (!function_exists('homeops_wd_discover_temp')) {
    function homeops_wd_discover_temp($device, $oid, $index, $type, $descr, $value, $limit, $limit_warn)
    {
        if (!is_numeric($value) || !function_exists('discover_sensor')) {
            return;
        }

        $params = (new ReflectionFunction('discover_sensor'))->getParameters();
        $first  = $params[0]->getName();

        // Classic: discover_sensor($valid, $class, $device, $oid, $index, $type, $descr, $divisor, $multiplier, $low, $low_warn, $warn, $high, $current)
        if (in_array($first, array('valid', 'valid_sensor', 'valid_sensors'), true)) {
            global $valid;
            if (!isset($valid['sensor']) || !is_array($valid['sensor'])) {
                $valid['sensor'] = array();
            }
            discover_sensor($valid['sensor'], 'temperature', $device, $oid, $index, $type, $descr, 1, 1, null, null, $limit_warn, $limit, $value);
            return;
        }

        // Current: discover_sensor($class, $device, $oid, $index, $type, $descr, $scale, $value, $options)
        $options = array(
            'limit_high'      => $limit,
            'limit_high_warn' => $limit_warn,
            'limit'           => $limit,
            'limit_warn'      => $limit_warn,
        );
        discover_sensor('temperature', $device, $oid, $index, $type, $descr, 1, $value, $options);
    }
}

$wd_chassis_oid = '.1.3.6.1.4.1.5127.1.1.1.8.1.7.0';
$wd_chassis_raw = homeops_wd_snmp_get($device, $wd_chassis_oid);
$wd_chassis_c   = homeops_wd_parse_centigrade($wd_chassis_raw);

// Not a WD My Cloud (or SNMP failed). Leave every other Linux device alone.
if ($wd_chassis_c === false && !preg_match('/Centigrade:/i', (string) $wd_chassis_raw)) {
    return;
}

if (function_exists('print_debug')) {
    print_debug('MYCLOUDEX2ULTRA-MIB: WD My Cloud temperatures on ' . $device['hostname']);
}

if ($wd_chassis_c !== false) {
    homeops_wd_discover_temp(
        $device,
        $wd_chassis_oid,
        'chassis',
        'mycloudex2ultra',
        'Chassis',
        $wd_chassis_c,
        62,
        55
    );
}

for ($i = 1; $i <= 4; $i++) {
    $temp_oid = '.1.3.6.1.4.1.5127.1.1.1.8.1.10.1.5.' . $i;
    $temp_c   = homeops_wd_parse_centigrade(homeops_wd_snmp_get($device, $temp_oid));
    if ($temp_c === false) {
        continue;
    }

    $vendor = homeops_wd_snmp_get($device, '.1.3.6.1.4.1.5127.1.1.1.8.1.10.1.2.' . $i);
    $model  = homeops_wd_snmp_get($device, '.1.3.6.1.4.1.5127.1.1.1.8.1.10.1.3.' . $i);
    $serial = homeops_wd_snmp_get($device, '.1.3.6.1.4.1.5127.1.1.1.8.1.10.1.4.' . $i);

    $descr = 'Disk ' . $i;
    foreach (array($vendor, $model) as $part) {
        if ($part !== false && $part !== '' && !preg_match('/^(N\/A|--)$/i', $part)) {
            $descr .= ' ' . $part;
        }
    }
    if ($serial !== false && $serial !== '' && !preg_match('/^(N\/A|--)$/i', $serial)) {
        $descr .= ' (' . $serial . ')';
    }

    homeops_wd_discover_temp(
        $device,
        $temp_oid,
        'disk.' . $i,
        'mycloudex2ultra',
        $descr,
        $temp_c,
        58,
        52
    );
}

unset($wd_chassis_oid, $wd_chassis_raw, $wd_chassis_c, $i, $temp_oid, $temp_c, $vendor, $model, $serial, $descr);
