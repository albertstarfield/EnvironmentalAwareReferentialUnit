# How to Read EARU_data.dat

> [!WARNING]
> **THIS is NOT an accurate physical device, it will drift eventually! If you want an exact measurement, purchase/use the actual external sensors!**

`EARU_data.dat` is the primary real-time state storage for the **EnvironmentalAwareReferentialUnit (EARU)**. It is written asynchronously by an ordinary background daemon that tries to be minimum capable to help read the sensors cleanly.

## File Structure
The file consists of two parts:
1.  **Main JSON Payload:** A single-line JSON object containing all sensor states and derived metrics.
2.  **Recovery Footer:** A redundant copy of the payload for data integrity, formatted as:
    `[RECOVERY_V1:<base64_encoded_payload>:<sha256_hash>]`

---

## Variable Definitions

### 1. Root Level
| Variable | Unit | Description |
| :--- | :--- | :--- |
| `time` | Seconds | Unix timestamp of the data sample (C system time). |
| `lid_angle` | Degrees | The current angle of the laptop lid (0° = closed). |
| `lid_speed` | deg/s | Dynamic filtered angular velocity of the lid movement. |
| `als` | Object | Dictionary containing `lux_factor` (0.0 to 1.0) and `spectral` (List of 4 integer RGB-proxy hardware channels). |
| `high_res_drift` | Mixed | High-resolution clock drift monitoring data. |
| `events` | List | Recent significant environmental, system, or lockout events (e.g. `"ALT_INOP"`). |
| `pedometer` | Object | Dictionary containing root steps counter: `{"steps": Integer}`. |
| `master_warning`| Bool | Active avionics emergency warning flag (critical sensors, drift interference, or alt lockout). |
| `master_caution`| Bool | Active caution flag (solder joint stress exceedances, high CPU/memory consumption > 90%). |
| `alt_inop` | Bool | Active Dead Reckoning Altitude INOP lockout safety status (true during altitude lockout). |

### 2. `accel` (Accelerometer)
| Variable | Unit | Description |
| :--- | :--- | :--- |
| `x`, `y`, `z` | m/s² | Raw acceleration components in the body frame. |
| `mag` | G | Total acceleration magnitude (1.0 = standard gravity). |

### 3. `gyro` (Gyroscope)
| Variable | Unit | Description |
| :--- | :--- | :--- |
| `x`, `y`, `z` | deg/s | Angular velocity around the X, Y, and Z axes. |

### 4. `orientation` (IMU AHRS)
Derived using the Mahony Filter (Accel + Gyro fusion).
| Variable | Unit | Description |
| :--- | :--- | :--- |
| `roll`, `pitch`, `yaw` | Degrees | Euler angles representing the device's attitude. |
| `q` | List | Quaternion representation `[w, x, y, z]`. |

### 5. `location` (Positioning & Dynamics)
| Variable | Unit | Description | Possible Outputs |
| :--- | :--- | :--- | :--- |
| `lat`, `lon` | Degrees | Geographic coordinates (Latitude, Longitude). | -90 to 90 / -180 to 180 |
| `alt` | Meters | Altitude above sea level (GPS/topo combined or dead-reckoned). | |
| `alt_rate` | m/s | Vertical velocity (climb/sink rate). | |
| `pressure_hpa` | hPa | Local atmospheric pressure. | ~950 to 1050 |
| `heading` | Degrees | Bearing relative to North. | 0 to 360 |
| `compass_dir` | String | Cardinal direction. | "N", "NE", "E", etc. |
| `v_mag` | m/s | Horizontally scaled ground speed magnitude. | |
| `vel` | List | Individual velocity components: `[vel_x, vel_y, vel_z]` in m/s. | |
| `mach` | Mach | Speed relative to the speed of sound. | |
| `calibrated_g` | m/s² | The local gravity constant used for IMU calibration. | ~9.80 |
| `pos` | Meters | Relative Cartesian position `[x, y, z]`. | |
| `total_distance_m` | Meters | Odometer for total distance traveled. | |
| `odometer_30m` | Meters | Distance traveled in the last 30 seconds. | |
| `transportation_category` | String | Mode/category of transit based on velocity and vibration patterns. | "Stationary", "Pedestrian/Walking", "Automotive/Transport", "High-Speed/Flight", "Rocket/Spaceflight", or one of the 7 override codenames: `flight_commercial_aviation_voyage`, `flight_general_aviation_voyage`, `stella_general_aviation_voyage`, `ground_transportation`, `sea_voyage_maritime_nautics`, `sea_voyage_general_maritime`, `significant_location_detection` |
| `CorrectionFactor_Reckoning_Velocity` | Ratio | Gain factor for horizontal velocity anchored to GPS (0.5 to 2.0). | |
| `CorrectionFactor_Reckoning_Heading` | Degrees | Additive offset for heading alignment anchored to GPS gradient. | |
| `CorrectionFactor_Reckoning_Altitude` | Meters | Additive offset for altitude anchored to GPS/TopoData. | |
| `CorrectionFactor_Reckoning_VerticalRate` | Ratio | Gain factor for vertical velocity anchored to GPS change. | |

### 6. `ecosystem_weather`
| Variable | Unit | Description | Possible Outputs |
| :--- | :--- | :--- | :--- |
| `category` | String | General weather condition. | "Stable / Dry", "Unstable", etc. |
| `dew_point_k` | Kelvin | Temperature at which air becomes saturated. | |
| `dew_point_spread` | Kelvin | Difference between ambient temperature and dew point. | |
| `air_fluid_density` | kg/m³ | Calculated local air density. | ~1.225 (Sea Level) |
| `pressure_tendency` | hPa | Rate of change of atmospheric pressure. | |
| `wind_map` | Object | Local wind vector interpolation and grid. | |

### 7. `seismic_activity` (Vibration & Fatigue)
| Variable | Unit | Description | Possible Outputs |
| :--- | :--- | :--- | :--- |
| `motion_type` | String | Classification of detected movement. | "Stationary", "Carried (Walking)", "Physical Shock", "Turbulent Flight", "Rocket / High-G Flight", "Automotive / Transport", "Seismic Activity (Ground)", "Intentional Hardware Torture" |
| `certainty` | 0.0-1.0 | Confidence in the `motion_type` classification. | |
| `spectral_balance` | Ratio | Ratio of high-freq to low-freq vibration energy. | -1.0 (Low Freq) to 1.0 (High Freq) |
| `peak_g` | G | Maximum G-force impulse detected in the last sample. | |

#### `damage_fatigue` (Reliability Index)
| Variable | Unit | Description |
| :--- | :--- | :--- |
| `solder_fatigue_prob` | 0.0-1.0 | Probability of SAC305 solder joint failure based on cumulative strain. |
| `electromech_fatigue_prob` | 0.0-1.0 | Heuristic risk of mechanical failure (Hinge/Cables). |
| `aggregated_risk` | 0.0-1.0 | Combined unreliability index for the hardware. |
| `cumulative_fatigue` | Units | Total accumulated damage units (Miner's Rule + Habibie). |
| `seu_risk_multiplier` | Ratio | Risk of Single Event Upsets due to altitude (1.0 = Sea Level). |
| `alt_stress_multiplier` | Ratio | Cooling/Thermal efficiency penalty due to altitude. |
| `anomaly_event_upset` | Count | Detected data corruption or clock rollback events. |

### 8. `system` (Resource Usage)
| Variable | Unit | Description |
| :--- | :--- | :--- |
| `cpu_usage` | % | CPU utilization. |
| `mem_usage` | % | Memory utilization. |
| `load_avg` | List | 1, 5, and 15-minute system load averages. |
| `uptime_system` | Seconds | System uptime. |
| `uptime_earu` | Seconds | Process uptime for EARU. |
| `battery_percent` | % | Current battery level. |
| `battery_charging` | Bool | Whether the system is plugged into power. |
| `BatteryEnergyBankWh` | Wh | Remaining energy in the battery in Watt-hours. |
| `BatteryFullChargeCapacityWh` | Wh | Maximum energy the battery can hold at its current health. |
| `BatteryDesignCapacityWh` | Wh | Original energy capacity of the battery when new. |
| `BatteryHealthPct` | % | Battery health (Full Charge Capacity / Design Capacity). |
| `pmset_info` | String | Raw output from macOS `pmset -g live`. |

### 9. `loop_consistency` (Performance)
Metrics regarding the stability of the main 100Hz sensor loop.
| Variable | Unit | Description |
| :--- | :--- | :--- |
| `avg_ms` | ms | Average loop execution time. |
| `pct_90_ms` | ms | 90th percentile execution time. |
| `low_1_ms` | ms | 1st percentile execution time. |
| `stutters` | Count | Number of times the loop exceeded the 10ms (100Hz) target. |
| `stutter_warning`| Bool | True if stutters were detected in the last window. |
| `wcef_latency` | ps | Worst-Case Execution Frame (WCEF) latency, representing the maximum loop duration inside the sliding window in picosecond units. |

### 10. `smc` (System Management Controller)
| Variable | Unit | Description |
| :--- | :--- | :--- |
| `temps` | Kelvin | Dictionary of internal temperature sensors (e.g., `TCMz` for CPU). |
| `ambient_temp_k` | Kelvin | Derived ambient air temperature. |
| `airflow_inlet_k` | Kelvin | Temperature of air entering the chassis. |
| `airflow_outlet_k` | Kelvin | Temperature of air exiting the chassis. |
| `fan_rpms` | List | Current rotation speed for each fan. |
| `heatflux_j` | Joules | Estimated convective heat transfer rate. |
| `massflow_kg_s` | kg/s | Air mass flow rate through the cooling system. |
| `thrust_n` | Newtons | Force exerted by the cooling fans. |
| `humidity_pct` | % | Estimated relative humidity. |
| `power` | Watts | Power consumption (derived from `PSTR`). |
| `PowerRateUsage` | Watts | Duplicate of `power`. |
| `cooling_efficiency_pct`| % | Convective thermal exhaust extraction efficiency. |
| `work_efficiency_pct` | % | Derived computational work efficiency ($100 - \text{cooling\_efficiency\_pct}$). |
| `thermal_inefficiency_w`| Watts | Power dissipated as heat losses in the cooling system. |
| `DayPowerUsage_Wh` | Wh | Cumulative energy consumption for the current day. |
| `EstimatedTodayPowerUsage_Wh` | Wh | Project total energy consumption for the end of the day. |
| `AccumulativePowerUsageThisMonth_Wh` | Wh | Cumulative energy consumption for the current month. |
| `AccumulativePowerUsageMeter_Wh` | Wh | Lifetime cumulative energy consumption (total meter). |
| `WillBatterySurviveOneDay` | String | "Yes" or "No" prediction based on current bank vs projected usage. |
| `inOrderToSurviveDayMustHibernate` | String | "Yes" if even pulsing cannot save enough energy, necessitating hibernation. |
| `PulsingSuggestionMaintenanceWindowWake` | Seconds | Suggested background wake interval to stretch battery life. |
| `PulsingSuggestionMaintenanceWindowWakeLength` | Seconds | Suggested duration for each background wake. |

### 11. `user_entity_detection` (BCG Heartbeat & Mood)
Detects physiological signals and presence through the chassis using the IMU.
| Variable | Unit | Description | Possible Outputs |
| :--- | :--- | :--- | :--- |
| `detected` | BPM | The heartbeat rate of the primary target measured by BCG proxy. | 55.0 to 165.0 |
| `count` | Integer | Number of other neighboring entities detected. | |
| `inferred_mood` | Probability | Probability map of the detected primary user's mood. | "Calm/Relaxed", "Excited/Joyful", "Tired/Bored", "Anxious/Frustrated" |
| `confidence` | 0.0-1.0 | Heartbeat estimation certainty rating. | |

---

## WiFiLogger 2 / Davis API Compatibility
EARU emulates the **WiFiLogger 2** (Davis Instruments) local API. This allows third-party weather software to treat EARU as a professional Davis weather station.

| Method | Endpoint | Port | Format | Units |
| :--- | :--- | :--- | :--- | :--- |
| `GET` | `/wflexpj.json` | `3270` | Davis JSON (Strict) | Metric (C, hPa, mps) |
| `GET` | `/wflarch.json` | `3270` | Archive JSON (5 entries) | Metric (C, hPa, mps) |
| `GET` | `/` | `3270` | Davis JSON | Metric (C, hPa, mps) |

### Davis Field Mapping
| Davis Key | EARU Source |
| :--- | :--- |
| `OT` / `IT` | Outdoor / Indoor Temp (Celsius) |
| `OH` / `IH` | Outdoor / Indoor Humidity (%) |
| `AP` | Atmospheric Pressure (hPa) |
| `WS` / `WD` | Wind Speed (mps) / Direction (deg) from WindMap |
| `RR` | Rain Rate proxy from dew point risk |
| `raind` / `rainmon`| Daily / Monthly Rain (accumulated) |

### Integration Example (Home Assistant)
Configure your Davis integration to point to `http://[YOUR_IP]:3270/wflexp.json`.

## Technical Implementation Notes
- **JSON Encoding:** Numpy integers and floats are converted to standard JSON types. Binary `als` data is hex-encoded.
- **Data Integrity:** The `parity` field inside the JSON and the `RECOVERY_V1` footer allow for validation of every write operation.
- **Sampling Rate:** Updated at 5Hz-10Hz depending on motion and system load. (Main physical IMU sensor loop remains 100Hz-800Hz).
