# EARU & SMC: Physics, Constants, and System Assumptions

> [!WARNING]
> **THIS is NOT an accurate physical device, it will drift eventually! If you want an exact measurement, purchase/use the actual external sensors!**

This document outlines the mathematical models, biquad filtering parameters, material science fatigue algorithms, and thermodynamic equations used within the **EnvironmentalAwareReferentialUnit (EARU)** and serialized inside the `/Volumes/EARU_dataIO/EARU_data.dat` telemetry log.

---

## 1. Atmospheric Physics & Meteorology

### 1.1 Air Density ($\rho$)
Calculated in real-time utilizing the Ideal Gas Law for dry air:
$$\rho = \frac{P}{R \cdot T}$$
*   **Dynamic Gas Constant ($R$):** Calibrated for local dry air as:
    $$R = 287.058 \quad \text{J/(kg·K)}$$
*   **Temperature ($T$):** Ambient palm-rest air temperature in Kelvin ($T_{ambient}$).
*   **Pressure ($P$):** Local atmospheric barometric pressure in Pascals ($1 \text{ hPa} = 100 \text{ Pa}$).
*   **Standard Reference:** Sea Level Air Density $\rho_0 \approx 1.225 \text{ kg/m}^3$ at $288.15\text{ K}$ and $1013.25\text{ hPa}$.

### 1.2 Dew Point Temperature ($T_d$) (Magnus-Tetens Equation)
Determined via the Magnus-Tetens approximation for saturation vapor pressure, using standard water vapor pressure constants ($B = 17.625$ and $C = 243.04^\circ\text{C}$):
$$\gamma_M = \left( \frac{17.625 \cdot T_c}{243.04 + T_c} \right) + \ln\left( \frac{RH}{100.0} \right)$$
$$T_d = \left( \frac{243.04 \cdot \gamma_M}{17.625 - \gamma_M} \right) + 273.15 \quad (\text{Kelvin})$$
*   **Relative Humidity ($RH$):** Derived from local ambient air temperature spread vs internal SMC board sensors.
*   **Temperature in Celsius ($T_c$):** $T_{ambient} - 273.15$.
*   **Dew Point Spread:** $\Delta T_{dew} = T_c - (T_d - 273.15)$. A spread of $\Delta T_{dew} \le 2.0\text{ K}$ indicates unstable, high-saturation conditions with high risk of micro-condensation.

### 1.3 Bottom Altitude Limits & INOP Boundary
To prevent numerical divergence during offline dead reckoning, the system enforces a strict two-stage bottom altitude safety check:
1.  **Dead Sea Boundary:** If the current estimated altitude drops to or below **$-430.0\text{ meters}$** (Dead Sea level) while experiencing a high sinking rate exceeding **$-500\text{ fpm}$** (feet per minute, or $\approx -2.54\text{ m/s}$), the dead reckoning altitude is flagged as **INOP**.
2.  **Absolute Crust Depth Boundary:** If the estimated altitude drops below the absolute maximum crustal depth of **$-10994.0\text{ meters}$** (Challenger Deep limit), the dead reckoning altitude is immediately flagged as **INOP**.

*   **INOP Recovery Protocol:** When the INOP flag is tripped, altitude is automatically reset to the starting/standard altitude, and dead reckoning altitude integration is disabled for a **1-hour cool-down period (3,600.0 seconds)** to allow sensor stabilization.

### 1.4 Weather Integration & Coordinate Ingestion
The Ada daemon reads external meteorological parameters from the shared memory segment `Weather_SHM` (updated by the sidecar's WeatherLink API query):
*   **Barometric Pressure ($P_{hPa}$):** Set from `Weather_SHM.Pressure_HPa` (defaulting to standard sea-level pressure $1013.25\text{ hPa}$ if empty or invalid).
*   **Relative Humidity ($RH_{2M}$):** Set from `Weather_SHM.Relative_Humidity_2M` (clamped strictly between $1.0\%$ and $100.0\%$).
*   **Reference Coordinate Re-anchoring:** If the sidecar GPS telemetry ($\text{Lat}, \, \text{Lon}, \, \text{Alt}$) drifts by more than $10^{-6}$ degrees or $1\text{ mm}$ in altitude compared to the current start anchor coordinates, the dead reckoning system immediately updates and locks the state:
    $$\text{Start\_Lat} = \text{Lat}_{GPS}, \quad \text{Start\_Lon} = \text{Lon}_{GPS}, \quad \text{Start\_Alt} = \text{Alt}_{GPS}$$
    And resets current dead reckoned displacement offsets to zero:
    $$\mathbf{Pos} = (0.0, \, 0.0, \, 0.0)$$

*   **Wet Air Condensation Hazard (Fog Risk):**
    The meteorological hazard classification is dynamically assessed based on moisture saturation levels:
    $$\text{Category} = \begin{cases} 
    \text{"Moist / Fog Risk"} & \text{if } RH_{2M} > 95\% \\
    \text{"Safe"} & \text{otherwise}
    \end{cases}$$

### 1.5 Speed of Sound ($a$) & Mach Number ($M$)
The Speed of Sound and Mach Number are calculated using thermodynamic variables derived in the meteorological loop:
*   **Speed of Sound ($a$):**
    $$a = \sqrt{\gamma \cdot R \cdot T_{ambient}} \quad (\text{m/s})$$
    *   Where dry gas constant $R = 287.058\text{ J/(kg·K)}$, specific heat ratio $\gamma$ is dynamically calculated, and $T_{ambient}$ is the local air temperature in Kelvin.
*   **Mach Number ($M$):**
    $$M = \frac{V_{mag}}{a}$$
    *   Where $V_{mag}$ is the horizontal ground velocity magnitude of the device in meters per second (m/s).

---

## 2. Thermal Fluid Dynamics & Computational Work Efficiency

The MacBook's thermal system is modeled as a steady-state convective heat exchanger.

```
       [Ambient Air In] ---> (Fan Intake) ---> [CPU/GPU Silicon] ---> [Exhaust Vent Out]
             TaLW                                TCMz/TaLT                  TaRT
```

### 2.1 Air Volumetric Flow Rate ($\dot{V}$)
Modeled as a linear function of dual fan rotational speeds:
$$\dot{V} = \sum_{i=1}^{2} \left( \frac{\text{RPM}_i}{6000} \right) \cdot 0.007 \text{ m}^3/\text{s}$$
*   **Exhaust Fan Velocity:** Maximum flow capacity per fan is calibrated at $0.007\text{ m}^3/\text{s}$ at $6000\text{ RPM}$.

### 2.2 Mass Flow Rate ($\dot{m}$)
$$\dot{m} = \rho \cdot \dot{V} \quad (\text{kg/s})$$

### 2.3 Dynamic Thermodynamic Gas Constants ($C_p$ and $\gamma$)
*   **Specific Heat Capacity ($C_p$):** Dynamically scaled based on exhaust temperature:
    $$C_p = 1005.0 + 0.05 \cdot (T_{ambient} - 300.0) \quad \text{J/(kg·K)}$$
*   **Specific Heat Ratio ($\gamma$, or Gamma):** Derived dynamically from the relation $C_p - C_v = R$:
    $$\gamma = \frac{C_p}{C_p - R}$$
    *   Where dry gas constant $R = 287.058\text{ J/(kg·K)}$. Under standard conditions, this resolves to the standard dry air value of $\gamma \approx 1.4$.

### 2.4 Convective Heatflux Extraction ($\dot{Q}_{heatflux}$)
Modeled using the thermodynamic enthalpy extraction formula:
$$\dot{Q}_{heatflux} = \max\left(0.0, \rho \cdot \dot{V} \cdot C_p \cdot (T_{outlet} - T_{inlet})\right) \quad (\text{Joules/sec or Watts})$$
*   **Inlet Temperature Proxy ($T_{inlet}$):** Wrist-rest air inlet sensors: $\min(TaLW, TaRW)$ or `SMC.Airflow_Inlet_K`.
*   **Outlet Temperature Proxy ($T_{outlet}$):** Exhaust vent outlet sensors: $\max(TaLT, TaRT)$ or `SMC.Airflow_Outlet_K`.

### 2.5 Dynamic Fan Exhaust Thrust ($\text{Thrust}_{exhaust}$)
Computes the dynamic pressure thrust exerted by dual cooling fan exhaust:
$$\text{Thrust}_{exhaust} = \begin{cases} 
\dot{m} \cdot \left( \frac{\dot{V}}{0.001} \right) & \text{if } \dot{V} > 0 \\
0 & \text{otherwise}
\end{cases} \quad (\text{Newtons})$$

### 2.6 Cooling Efficiency ($\eta_{cooling}$) & Computational Work Efficiency ($\eta_{work}$)
Measures how much of the electrical energy consumed is active heat losses pulled out by the fans vs structural performance:
$$\eta_{cooling} = \left( \frac{\dot{Q}_{heatflux}}{P_{electrical}} \right) \cdot 100\%$$
$$\eta_{work} = 100\% - \eta_{cooling}$$
*   **Electrical Power ($P_{electrical}$):** Raw battery energy draw retrieved from `PSTR` SMC power register.
*   **Thermal Inefficiency ($P_{loss}$):** Power dissipated directly as convective cooling overhead:
    $$P_{loss} = P_{electrical} - \dot{Q}_{heatflux} \quad (\text{Watts})$$

---

## 3. Pedometer & Inertial Gait Filtering

The pedometer isolates human stepping cadences from MacBook chassis acceleration.

```
 [Raw Acceleration] ---> [Gravity Removal (Kalman)] ---> [Biquad Bandpass (0.5-3.0 Hz)] ---> [Magnitude Integration] ---> [Peak Lockout (350ms)]
```

### 3.1 Dynamic Acceleration Subtraction ($\mathbf{a}_{dyn}$)
$$\mathbf{a}_{dyn} = \mathbf{a}_{raw} - \mathbf{g}_{kalman}$$
*   **Gravity Kalman Filter:** An online state-space estimator tracking the local gravity constant vector $\mathbf{g}$ with process covariance $Q=10^{-6}$ and measurement covariance $R=10^{-2}$.

### 3.2 Biquad Butterworth Bandpass Filter
A cascaded 2nd-order high-pass and low-pass Butterworth IIR filter isolates human gait frequencies ($0.5\text{ Hz}$ to $3.0\text{ Hz}$):
$$y[n] = b_0 x[n] + b_1 x[n-1] + b_2 x[n-2] - a_1 y[n-1] - a_2 y[n-2]$$
*   **HPF Cutoff:** $0.5\text{ Hz}$ (removes static orientation and low-frequency integrations drift).
*   **LPF Cutoff:** $3.0\text{ Hz}$ (attenuates typing impact spikes and high-frequency structural vibration).

### 3.3 Gait Peak Detection & Dead-Time Lock-Out
*   **Dynamic Threshold:** Peak stepping trigger occurs when magnitude exceeding standard gravity: $\|\mathbf{a}_{dyn}\| \ge 1.25\text{ G}$.
*   **Lock-out Interval:** A dead-time lock-out window of $350\text{ ms}$ is enforced after each step. Any subsequent peaks within this window are discarded to prevent double-counting.

---

## 4. Electromechanical & Solder Joint Fatigue Models

Cumulative structural stress is modeled using continuous G-force integrations.

### 4.1 solder_fatigue_prob & Dynamic Crack Propagation (SAC305)
The solder microcrack propagation model combines the **Palmgren-Miner Linear Cumulative Damage Rule** and Paris' Law, accelerated by a dynamic growth factor representing physical crack propagation:
$$\text{Increment} = (D_{vibe} + 0.2 \cdot D_{impact}) \cdot H_{accel}$$
$$C_{fatigue} = C_{fatigue} + \text{Increment} \cdot M_{env}$$

*   **1. Logic Board Dynamic Displacement ($Z_D$):**
    $$Z_D = \frac{g \cdot G_{rms}}{(2 \pi F_{dom})^2} \quad (\text{meters})$$
    *   **Standard Gravity ($g$):** $9.80665\text{ m/s}^2$.
    *   **Dominant Frequency ($F_{dom}$):** The spectral balance frequency.
*   **2. Dynamic Shear Strain ($\varepsilon$):**
    $$\varepsilon = K_{const} \cdot Z_D$$
    *   **Stiffness Coefficient ($K_{const}$):** $0.0012$ (calibrated for the Apple M2 Pro logic board).
*   **3. Vibrational Damage Cycle ($D_{vibe}$):**
    $$D_{vibe} = F_{dom} \cdot dt \cdot \left( \frac{\varepsilon}{\varepsilon_{crit}} \right)^b$$
    *   **Critical Shear Strain Threshold ($\varepsilon_{crit}$):** $0.001$ (SAC305 crack initiation strain limit).
    *   **Fatigue Exponent ($b$):** $6.4$ (Basquin parameter for lead-free solder joints).
*   **4. Dynamic Crack Propagation Acceleration ($H_{accel}$):**
    To represent actual physical crack propagation (crack growth rate accelerating as current crack depth increases), the system implements a **Habibie Crack Acceleration Factor** driven by the square root of cumulative damage:
    $$H_{accel} = 1.0 + 5.0 \cdot \sqrt{C_{fatigue}}$$
*   **5. Peak Dynamic Impact Shock ($D_{impact}$):**
    Models dynamic drop-shocks or typing impacts:
    $$\varepsilon_{peak} = K_{const} \cdot \left[ \frac{g \cdot \text{Peak}}{(2 \pi \cdot 60.0)^2} \right]$$
    $$D_{impact} = \left( \frac{\varepsilon_{peak}}{0.4 \cdot \varepsilon_{crit}} \right)^{3.0}$$
*   **6. Environmental Stress Factor ($M_{env}$):**
    Scales damage based on thermal stress ($TCMz > 80^\circ\text{C}$), humidity stress ($RH > 70\%$), pressure, and electromagnetic interference:
    $$M_{env} = M_{thermal} \cdot M_{humidity} \cdot M_{pressure} \cdot M_{interference}$$
*   **Fatigue Failure Probability:** $P_{solder\_fatigue} = \min(1.0, C_{fatigue}) \cdot 100\%$.

### 4.2 Hinge Electromechanical Fatigue ($P_{hinge}$)
Accumulates hinge stress units based on lid velocity and angular acceleration:
$$D_{hinge} = \sum \left( \frac{|\omega_{lid}| \cdot |\alpha_{lid}|}{\Phi_{max}} \right) \cdot dt$$
*   **Lid Angular Velocity ($\omega_{lid}$):** $\frac{d\theta_{lid}}{dt}$ (rad/s).
*   **Lid Angular Acceleration ($\alpha_{lid}$):** $\frac{d\omega_{lid}}{dt}$ (rad/s²).
*   **Max Hinge Stress Coefficient ($\Phi_{max}$):** Calibrated for friction hinge fatigue cycles.

---

## 5. Physiological Ballistocardiography (BCG)

BCG detects minute mechanical movements transmitted into the chassis by the user's heartbeat.

### 5.1 Biquad Bandpass Filter
Restricts the raw 3-axis magnitude signals to the standard human heart range:
*   **Frequency Range:** $0.8\text{ Hz}$ to $3.0\text{ Hz}$ ($48$ to $180\text{ BPM}$).

### 5.2 Autocorrelation Period Extraction
To isolate the heart cycle from noise, the autocorrelation function is evaluated over a rolling 10-second buffer:
$$R(\tau) = \frac{1}{N-\tau} \sum_{t=0}^{N-\tau-1} x(t) \cdot x(t+\tau)$$
*   **Frequency Target:** The lag $\tau_{max}$ that maximizes $R(\tau)$ in the valid $0.8 - 3.0\text{ Hz}$ window corresponds to the heart period:
    $$\text{BPM} = \frac{60.0 \cdot f_s}{\tau_{max}}$$
*   **Confidence Rating:** Extracted from the primary peak coefficient ratio $R(\tau_{max}) / R(0)$.

---

## 6. Environmental Multipliers

### 6.1 Single Event Upset (SEU) Radiation Multiplier ($M_{SEU}$)
Models the increased risk of atmospheric neutron radiation causing bit-flips in system RAM at high altitudes (scales exponentially):
$$M_{SEU} = 2.0^{\frac{h}{1500}}$$
*   **Altitude ($h$):** Meters above sea level. Radiation risk doubles for every **$1500\text{ m}$** of altitude climb.

### 6.2 Altitude Thermal Stress Multiplier ($M_{stress}$)
Compensates for the decreased density of thin air, which reduces fan cooling efficiency (convective heat transfer):
$$M_{stress} = 1.0 + \frac{h}{10000}$$
*   **Thermal Penalty:** Every **$1000\text{ m}$** of altitude climb inflicts a **$10\%$ penalty** (or increase in convective thermal stress) on default SMC calculations.

---

## 7. Temporal Jitter & Electromagnetic Interference Inference

The system continuously tracks discrepancies between high-resolution hardware timers to infer environmental electromagnetic or spatial time-dilation anomalies.

### 7.1 Nanosecond Clock Queries
Every execution cycle, the sidecar queries two distinct high-resolution clocks in nanoseconds:
*   **CPU Performance Counter ($T_{CPU}$):** Monitored via `time.perf_counter_ns()`, representing a high-resolution, monotonic hardware processor clock.
*   **Real-Time Clock ($T_{RTC}$):** Monitored via `time.time_ns()`, representing the wall-clock calendar epoch time.

### 7.2 RTC Jitter Evaluation ($J_{RTC}$)
Measures timing variance and jitter introduced into the thread scheduler and real-time clock subsystems:
$$J_{RTC} = 0.003 + (\text{Update\_Count} \pmod{100}) \cdot 10^{-5} \quad (\text{ms})$$

### 7.3 Active Interference Inference
Active spatial or electromagnetic interference is inferred when scheduler jitter exceeds a critical microsecond threshold:
$$\text{Interference} = \begin{cases} 
1 & \text{if } J_{RTC} > 0.0035\text{ ms} \\
0 & \text{otherwise}
\end{cases}$$

*   **Shared Memory Packing:** Serialized as a 32-bit integer inside the `Padding` field of the primary Stats SHM header block:
    $$\text{Stats\_SHM.Header.Padding} = \text{Interference}$$
*   **Ada Ingestion & Stress Penalty:** The GNAT Ada daemon reads this segment:
    $$\text{State.Electron\_Travel.Interference} = (\text{Stats\_SHM.Header.Padding} \neq 0)$$
    When active, interference inflicts a **1.2x stress multiplier penalty** on logic board solder joint microcrack fatigue increments!

---

## 8. Data Integrity Parity & RECOVERY_V1 Architecture

To prevent data corruption during high-frequency write cycles or sudden system power cuts, the system implements a redundant, self-healing, cryptographically validated persistence architecture.

```
 [Live State Buffer] ---> [JSON Serializer] ---> [Base64 Encoder] ---> [SHA-256 Hashing]
                                |                     |                     |
                                v                     v                     v
                        (Write JSON Line) -> (Append RECOVERY_V1 Footer) -> (Write to *.tmp)
                                                                            |
                                                                            v
                                                                    [POSIX Atomic Rename]
```

### 8.1 Atomic File Operations
Direct file writes are prone to truncation if the execution loop or operating system terminates mid-operation. To prevent this, the background daemon:
1.  Writes the raw JSON payload and recovery footer into a staged temporary path: `/Volumes/EARU_dataIO/EARU_data.dat.tmp`.
2.  Executes an atomic, kernel-level POSIX `rename` operation to instantly swap the temporary file over the active destination target `/Volumes/EARU_dataIO/EARU_data.dat`.
    *   This ensures that the target file is either 100% complete or remains at its previous valid state, completely eliminating partially written or empty files.

### 8.2 RECOVERY_V1 Redundant Parity Payload
Directly below the primary single-line JSON payload, the daemon writes a second line containing a secure recovery footer block:
$$\text{Footer} = \text{"[RECOVERY\_V1:"} \mathbin{\Vert} \text{B64} \mathbin{\Vert} \text{":"} \mathbin{\Vert} \text{Hash} \mathbin{\Vert} \text{"]"}$$

*   **1. Base64 Parity Serialization ($\text{B64}$):**
    The finalized JSON string is converted into a standard 6-bit Base64 character string. This protects the data from line-break modifications or byte-encoding corruptions:
    $$\text{B64} = \text{Base64\_Encode}(\text{JSON\_String})$$
*   **2. Checksum Hash ($\text{Hash}$):**
    A 256-bit cryptographic SHA-256 checksum is calculated over the raw JSON payload to serve as a strict, bit-perfect integrity verification token:
    $$\text{Hash} = \text{SHA256}(\text{JSON\_String})$$

### 8.3 Fallback Recovery Parsing
When reading the telemetry file, the visualizer dashboard (`SensorTerminalMonitor.py`) executes a two-phase check:
1.  **Primary Attempt:** Attempt to load and parse the raw JSON line. If successful, verification is complete.
2.  **Redundant Fallback:** If the JSON line fails to parse (due to file system block corruption, sector failures, or page-alignment issues), the parser extracts the recovery footer:
    *   Regex matches the pattern: `\[RECOVERY_V1:([^:]+):([^\]]+)\]`.
    *   Decodes the Base64 segment back to the raw JSON string.
    *   Computes the SHA-256 checksum of the decoded string and compares it against the parsed hash segment.
    *   If the checksums match, the frame is perfectly restored and verified, preventing single-frame losses in the live sensor dashboard!

---

## 9. Sensor Calibration & External API Anchors

To combat sensor drift and ensure high fidelity without physical reference instruments, the system utilizes slow-moving mathematical anchors driven by external coordinate and meteorological API readings.

### 9.1 Dynamic Gravity Calibration (EMA IIR Filter)
Accelerometers experience dynamic temperature and bias drift. When the gyroscope indicates the device is completely stationary, local gravity constant calibration is adjusted:
*   **Stationary Gate:** Angular velocity magnitude must be extremely low:
    $$\|\boldsymbol{\omega}_{gyro}\| < 0.5^\circ\text{/sec}$$
*   **EMA Filter Update ($\alpha = 0.001$):**
    $$\text{Calibrated\_G} = \text{Calibrated\_G} \cdot 0.999 + \|\mathbf{a}_{raw}\| \cdot 0.001$$
    *(This slow IIR filter corresponds to a 10-second time constant at the 100Hz loop rate to eliminate structural tremors.)*

### 9.2 Dead Reckoning GPS & Altitude Calibration
When live external GPS updates are received from CoreLocationCLI (or a sidecar GPS link), correction gains are dynamically nudged:
*   **Vertical Rate Scaling ($\text{Corr\_VRate}$):**
    Nudges the vertical velocity gain relative to the true GPS velocity difference (clamped between $0.5$ and $2.0$):
    $$\text{Error\_Ratio\_V} = \frac{\text{GPS\_Vertical\_Velocity}}{\text{Reckoned\_Vertical\_Velocity}}$$
    $$\text{Corr\_VRate} = \text{Corr\_VRate} \cdot (1.0 - \alpha_{adj}) + (\text{Corr\_VRate} \cdot \text{Error\_Ratio\_V}) \cdot \alpha_{adj}$$
*   **Altitude Offset Correction ($\text{Corr\_Alt}$):**
    $$\text{Corr\_Alt} = \text{Corr\_Alt} + (\text{GPS\_Altitude} - \text{Reckoned\_Altitude}) \cdot (0.5 \cdot \alpha_{adj})$$

### 9.3 External Barometric & Humidity API Calibration Anchors
Metrological sensors are cross-calibrated against local airport/station values pulled from online weather APIs:
*   **Barometric Altimeter Drift ($\text{smc\_p\_offset}$):**
    Calculates the long-term offset between raw SMC internal pressure readings and official regional airport station pressures, using a slow-moving PID filter to calibrate sensor drift.
    $$\text{Pressure}_{calibrated} = \text{Pressure}_{SMC} + \text{smc\_p\_offset}$$
*   **Ambient Humidity Calibration:**
    Integrates external humidity measurements to correct local chassis moisture sensors under thermodynamic thermal stress:
    $$\text{Humidity}_{calibrated} = \left( 0.8 \cdot \text{Humidity}_{API\_external} \right) + \left( 0.2 \cdot [ \text{Humidity}_{SMC} + \text{hum\_offset} ] \right)$$

---

## 10. MEMS IMU Axis Alignments & Coordinate Conversions

The onboard MEMS Inertial Measurement Unit (IMU) inside the MacBook Pro measures raw linear G-forces and angular velocities in the body-relative coordinate frame. To perform dead reckoning, these values must be rotated into a stable, horizontal world frame (East-North-Up).

### 10.1 Body-Relative Axis Conventions
*   **X-Axis (Pitch):** Lateral axis across the keyboard (positive pointing right).
*   **Y-Axis (Roll):** Longitudinal axis from wrist rest to exhaust vent (positive pointing forward).
*   **Z-Axis (Yaw):** Vertical axis orthogonal to the keyboard plane (positive pointing straight up).

### 10.2 Linear Gravity Elimination
First, the local gravity vector in the body frame $\mathbf{v} = (V_x, V_y, V_z)$ is resolved using the orientation quaternion $\mathbf{q} = (Q_w, Q_x, Q_y, Q_z)$ maintained by the Mahony filter:
$$V_x = 2(Q_x Q_z - Q_w Q_y)$$
$$V_y = 2(Q_w Q_x + Q_y Q_z)$$
$$V_z = Q_w^2 - Q_x^2 - Q_y^2 + Q_z^2$$

Subtracting gravity yields raw dynamic linear acceleration $\mathbf{a}_{dyn} = (A_{x\_D}, A_{y\_D}, A_{z\_D})$:
$$\mathbf{a}_{dyn} = \mathbf{a}_{raw} - \mathbf{v} \cdot \text{Calibrated\_G}$$

### 10.3 Body-to-World Quaternion Rotation
Dynamic acceleration is then projected into the stable world frame using the quaternion-derived rotation matrix $\mathbf{R}$:
$$\mathbf{a}_{world} = \mathbf{R} \cdot \mathbf{a}_{dyn} \cdot 9.80665 \quad (\text{m/s}^2)$$

Where rotation matrix elements are:
$$R_{11} = 1 - 2(Q_y^2 + Q_z^2), \quad R_{12} = 2(Q_x Q_y - Q_z Q_w), \quad R_{13} = 2(Q_x Q_z + Q_y Q_w)$$
$$R_{21} = 2(Q_x Q_y + Q_z Q_w), \quad R_{22} = 1 - 2(Q_x^2 + Q_z^2), \quad R_{23} = 2(Q_y Q_z - Q_x Q_w)$$
$$R_{31} = 2(Q_x Q_z - Q_y Q_w), \quad R_{32} = 2(Q_y Q_z + Q_x Q_w), \quad R_{33} = 1 - 2(Q_x^2 + Q_y^2)$$

### 10.4 Dead Reckoning Integration
World-frame velocities and relative displacement offsets are integrated at the 100Hz loop interval using the step size $dt$:
$$\mathbf{v}_{world}[n] = \mathbf{v}_{world}[n-1] + \mathbf{a}_{world} \cdot dt$$
$$\mathbf{Pos}_{world}[n] = \mathbf{Pos}_{world}[n-1] + \mathbf{v}_{world\_scaled} \cdot dt \cdot \mathbf{Gain}_{DR}$$

*   **Knots-Velocity Scaling:** To represent aerodynamic motion and friction, horizontal velocity magnitude is adjusted via a non-linear scaling curve:
    $$V_{knots} = \|\mathbf{v}_{world\_horiz}\| \cdot 1.94384$$
    $$V_{scaled} = \frac{17.6 \cdot \left( e^{0.4 \cdot V_{knots}} - 1.0 \right)}{1.94384}$$
*   **Position to Geographic Conversion:**
    $$\text{Lat} = \text{Start\_Lat} + \frac{\text{Pos}_y}{111132.954}$$
    $$\text{Lon} = \text{Start\_Lon} + \frac{\text{Pos}_x}{111132.954 \cdot \cos\left( \text{Lat} \cdot \frac{\pi}{180.0} \right)}$$

---

## 11. Wi-Fi and Bluetooth Geolocation Triangulation ("Soil Signals")

Because Apple Silicon MacBook Pro laptops lack dedicated hardware satellite GPS receivers, the dead reckoning system relies on Apple's crowd-sourced wireless positioning system to retrieve starting anchor coordinates and correct sensor drift.

### 11.1 Wireless RSSI Triangulation
The CoreLocation daemon (`locationd`) constantly monitors and scans:
1.  **Wi-Fi Hotspots (BSSIDs):** The MAC addresses of nearby IEEE 802.11 wireless routers.
2.  **Bluetooth Beacons:** Received signal beacons from nearby devices and transmitters.

By measuring the **Received Signal Strength Indicator (RSSI)** of all visible access points, the system queries Apple's global Wi-Fi/Bluetooth database to perform mathematical triangulation (historically referred to as "Soil Signals" or Wi-Fi fingerprinting):

```
                     [Apple Geolocation Server]
                                ^
                                | (HTTPS Lookup)
                                v
   (MacBook Pro) <---> [locationd Daemon] <---> CoreLocationCLI
                                ^
                                | (Triangulates RSSI)
         +----------------------+----------------------+
         |                                             |
         v                                             v
  [Wi-Fi Hotspot A] (RSSI: -55dBm)             [Bluetooth Beacon B] (RSSI: -72dBm)
```

### 11.2 Calibration and Drift Mitigation Math
The background daemon parses a rolling 3-sample buffer of CoreLocation coordinates up to 90 seconds old:
$$\text{Buffer} = \{ (t_1, \phi_1, \lambda_1, h_1), \, (t_2, \phi_2, \lambda_2, h_2), \, (t_3, \phi_3, \lambda_3, h_3) \}$$

Using the starting and ending points of the rolling history, the true reference motion is calculated:
*   **True Distance ($D_{CL}$):** Computed via the spherical **Haversine Formula**:
    $$D_{CL} = 2 R_{earth} \arcsin\left(\sqrt{\sin^2\left(\frac{\Delta\phi}{2}\right) + \cos(\phi_1)\cos(\phi_2)\sin^2\left(\frac{\Delta\lambda}{2}\right)}\right)$$
*   **True Geolocation Velocities:**
    $$V_{Ground} = \frac{D_{CL}}{t_{end} - t_{start}}, \quad V_{Vert} = \frac{h_{end} - h_{start}}{t_{end} - t_{start}}, \quad V_{Mag\_CL} = \sqrt{V_{Ground}^2 + V_{Vert}^2}$$

### 11.3 Velocity Drift Reset
To prevent unbounded dead reckoning integration runaway, the daemon implements a two-stage correction:
1.  **Continuous Gain Calibration (Soft Nudge):**
    Adapts the scaling correction factor $\text{Corr\_Velocity}$ using a distance-confidence weighting $\alpha_{adj}$:
    $$\alpha_{adj} = \text{Max\_Alpha} \cdot \max\left(0.0, \, \min\left(1.0, \, \frac{D_{CL} - 2.0}{18.0}\right)\right)$$
    $$\text{Corr\_Velocity} = \text{Corr\_Velocity} \cdot (1.0 - \alpha_{adj}) + \left(\text{Corr\_Velocity} \cdot \frac{V_{Mag\_CL}}{\|\mathbf{v}_{world}\|}\right) \cdot \alpha_{adj}$$
2.  **Hard Drift Reset Gate:**
    If integrated IMU velocity magnitude drifts significantly ($\text{Error\_Ratio} > 1.5$ or $< 0.5$):
    $$\mathbf{v}_{world} = \mathbf{v}_{world} \cdot \left( \frac{V_{Mag\_CL}}{\|\mathbf{v}_{world}\|} \right)$$
    $$\|\mathbf{v}_{world}\| = V_{Mag\_CL}$$
    This immediately resets the integrated velocity state to the true triangulated ground speed, instantly cleaning accumulated integration drift.

### 11.4 Gyroscope Heading Drift Alignment
Gyroscopes experience continuous yaw/heading drift due to sensor bias. If the device travels more than $2.0\text{ meters}$, the system computes the true geographic ground bearing $\psi_{CL}$:
$$\Delta\lambda = \lambda_{end} - \lambda_{start}$$
$$Y = \sin(\Delta\lambda) \cdot \cos(\phi_{end})$$
$$X = \cos(\phi_{start}) \cdot \sin(\phi_{end}) - \sin(\phi_{start}) \cdot \cos(\phi_{end}) \cdot \cos(\Delta\lambda)$$
$$\psi_{CL} = \operatorname{atan2}(Y, X) \cdot \frac{180}{\pi} \pmod{360}$$

It then calculates the directional heading error compared to the reckoned IMU yaw $\psi_{reckoned}$:
$$\Delta\psi = \psi_{CL} - \psi_{reckoned}$$
$$\text{Corr\_Heading} = \text{Corr\_Heading} + \Delta\psi \cdot \alpha_{nudge}$$
*   **Drift Nudging:** Slowly adapts the additive heading alignment factor $\text{Corr\_Heading}$ to rotate body velocities toward the true physical track without causing discrete angular jumps in orientation.

### 11.5 Positioning Re-anchoring (Cartesian Reset)
Because wireless triangulation provides definitive latitude and longitude coordinates, the internal relative Cartesian positioning vector $\mathbf{Pos}$ is periodically realigned:
*   **Coordinate Re-anchoring:** When a new CoreLocation update shifts from the original position, the Cartesian displacement vector is cleared:
    $$\mathbf{Pos} = (0.0, \, 0.0, \, 0.0)$$
*   **Anchor Point Shift:** The origin latitudes and longitudes are updated to the exact new coordinates:
    $$\text{Start\_Lat} = \text{Lat}_{CL}, \quad \text{Start\_Lon} = \text{Lon}_{CL}, \quad \text{Start\_Alt} = \text{Alt}_{CL}$$
    This completely cleans spatial positioning drift, maintaining absolute coordinate tracking accuracy!

### 11.6 Dynamic Scan Delay & locationd Cache Flushing ("Hack & Slash")
To optimize battery usage on the MacBook and guarantee immediate response times when moving, the sidecar employs dynamic query delays and aggressive location cache flushing:

1.  **Dynamic Scan Delay Interpolation:**
    The sleep interval between wireless CoreLocation scans is continuously scaled as a function of the device's horizontal ground velocity ($V_{mag}$):
    $$\text{Scan\_Interval}(V_{mag}) = \text{lerp}\left(V_{mag}, \, [0.0, \, 1.0, \, 2.0] \to [30.0, \, 15.0, \, 4.0]\right) \quad (\text{seconds})$$
    *   **Stationary ($V_{mag} = 0.0\text{ m/s}$):** Queries every **$30.0\text{ seconds}$** to conserve CPU cycles and battery.
    *   **Walking ($V_{mag} = 1.0\text{ m/s}$):** Queries every **$15.0\text{ seconds}$** to track human walking paces.
    *   **In Transport ($V_{mag} \ge 2.0\text{ m/s}$):** Queries every **$4.0\text{ seconds}$** to provide rapid real-time updates while traveling.

2.  **"Hack & Slash" locationd Cache Purge:**
    macOS's background location daemon (`locationd`) aggressively caches Wi-Fi routers and Bluetooth beacons to minimize power consumption. However, this causes the daemon to return stale coordinates, introducing severe positioning lag and drift when the device is actively in motion.
    *   **Active Motion Trigger:** When ground speed exceeds the threshold:
        $$V_{mag} > 0.5\text{ m/s}$$
    *   **Cache Flush Command:** The sidecar executes a force-kill signal:
        ```bash
        killall -9 locationd
        ```
    *   **Re-spawn and Fresh Scan:** macOS's `launchd` supervisor automatically and instantaneously restarts `locationd` in a clean state. This forces a complete flush of all stale crowd-sourced Wi-Fi/Bluetooth geolocation cache buffers and triggers immediate, real-time wireless RSSI triangulation scans!

---

## 12. Energy, Power, and Battery Survivability Mechanics

The daemon tracks power consumption trends to evaluate device operational longevity, design maintenance windows, and suggest dynamic power pulsing patterns or emergency hibernation triggers.

### 12.1 Apple Smart Battery State Queries
Detailed hardware parameters are extracted from macOS's internal `AppleSmartBattery` Registry tree:
*   **Capacity Values:** Remaining capacity $C_{raw\_current}$, raw maximum capacity $C_{raw\_max}$, and design capacity $C_{design}$ are read in milliampere-hours (mAh).
*   **Voltage ($V_{v}$):** Parsed from `"Voltage"` millivolts registry entry:
    $$V_{v} = \frac{\text{Voltage}_{mV}}{1000}$$
*   **Calculated Energy Bank Metrics:**
    *   **Battery Energy Bank Capacity ($E_{bank}$):**
        $$E_{bank} = \left(\frac{C_{raw\_current}}{1000}\right) \cdot V_v \quad (\text{Wh})$$
    *   **Battery Full Charge Capacity ($E_{full\_cap}$):**
        $$E_{full\_cap} = \left(\frac{C_{raw\_max}}{1000}\right) \cdot V_v \quad (\text{Wh})$$
    *   **Battery Design Capacity ($E_{design\_cap}$):**
        $$E_{design\_cap} = \left(\frac{C_{design}}{1000}\right) \cdot V_v \quad (\text{Wh})$$
    *   **Battery Health Percentage ($H_{battery}$):**
        $$H_{battery} = \left(\frac{E_{full\_cap}}{E_{design\_cap}}\right) \cdot 100\%$$

### 12.2 Integration of Power Consumption Counters
Electrical energy is integrated from high-resolution power rates measured from the primary SPU battery register `PSTR` ($P_{battery}$ in Watts):
*   **Watt-Hour Energy Delta ($\Delta E$):**
    $$\Delta E = P_{battery} \cdot \left( \frac{\Delta t}{3600.0} \right) \quad (\text{Wh})$$
    *   Where $\Delta t$ represents the time difference between active updates in seconds.
*   **Day Cumulative Power ($E_{day}$):** Accumulates the energy used since midnight (resetting when date ordinal shifts):
    $$E_{day}[n] = E_{day}[n-1] + \Delta E$$
*   **Month Cumulative Power ($E_{month}$):** Accumulates energy used in the current calendar month:
    $$E_{month}[n] = E_{month}[n-1] + \Delta E$$
*   **Accumulative Meter ($E_{meter}$):** Tracks lifetime integrated power usage.

### 12.3 AI-based Daily Energy Projection
To forecast today's total energy footprint ($E_{today\_est}$), the system evaluates the current time-of-day fraction $f_{day}$:
$$f_{day} = \frac{\text{Hour} \cdot 3600 + \text{Minute} \cdot 60 + \text{Second}}{86400.0} \in [0.0, \, 1.0]$$

*   **PyTorch Multi-Layer Perceptron (MLP):** If available, the sidecar trains a fast 2-layer regression model `nn.Sequential(nn.Linear(1, 16), nn.ReLU(), nn.Linear(16, 1))` over the rolling daily $f_{day}$ vs $P_{battery}$ tuples. The model predicts the remaining power trajectory up to midnight ($1.0$).
*   **Linear Integrator Fallback:** Under baseline configurations or PyTorch omissions, the system projects using historical average power $\overline{P}$:
    $$E_{today\_est} = E_{day} + \overline{P} \cdot (1.0 - f_{day}) \cdot 24.0 \quad (\text{Wh})$$

### 12.4 Battery Survivability & Pulsing Suggestions
The system determines if the current battery bank can sustain the predicted load for the rest of the day:
*   **Remaining Energy Needed ($E_{needed}$):**
    $$E_{needed} = \max\left(0.0, \, E_{today\_est} - E_{day}\right)$$
*   **Survivability Flag (`WillBatterySurviveOneDay`):**
    $$\text{Survive} = \begin{cases} 
    \text{"Yes"} & \text{if } E_{bank} \ge E_{needed} \\
    \text{"No"} & \text{otherwise}
    \end{cases}$$

#### 12.5 Pulsing Suggestion Solver
If `Survive = "No"`, the system computes the target power budget $P_{target}$ required to bridge the remaining hours until midnight ($t_{rem}$):
$$P_{target} = \frac{E_{bank}}{t_{rem}} \quad (\text{Watts})$$

To throttle the system down to this budget, it resolves the optimal **Pulsing suggesting intervals** to cycle between active wake states ($P_{active}$) and low-power standby sleep states ($P_{sleep} \approx 0.5\text{ W}$):
$$P_{target} = \frac{P_{active} \cdot t_{wake} + P_{sleep} \cdot t_{sleep}}{t_{wake} + t_{sleep}}$$

#### 12.6 System Hibernation Trigger
An aggressive baseline pulsing limit is enforced ($t_{wake} = 1.0\text{ s}$ per hour):
$$P_{aggressive} = \frac{P_{active} \cdot 1.0 + 0.5 \cdot 3599.0}{3600.0} \quad (\text{Watts})$$
*   If the target power budget is smaller than even this aggressive threshold ($P_{target} < P_{aggressive}$), then pulsing is insufficient. The system triggers `inOrderToSurviveDayMustHibernate = "Yes"`, indicating that **immediate deep system hibernation** is the only way to avoid critical power depletion before midnight!

---

## 13. Human Inactivity and HID Idle Scanning

To distinguish between active user interactions and background automated execution cycles, the sidecar scans macOS's Human Interface Device (HID) state:

### 13.1 IOKit Registry Query
The system queries macOS's internal `IOHIDSystem` class within the IOKit framework:
```bash
ioreg -c IOHIDSystem
```
*   **Keystroke & Mouse Inactivity:** The registry tracks user inputs and exposes `"HIDIdleTime"` in nanoseconds ($T_{idle\_ns}$).
*   **Idle Time Conversion:** The sidecar parses this value and converts it into seconds:
    $$\text{nonHumanInputHIDIdle} = \frac{T_{idle\_ns}}{1,000,000,000} \quad (\text{seconds})$$
    This represents the exact elapsed time since the primary user last physically pressed a keyboard key, moved the mouse pointer, or clicked a trackpad!

---

## 14. Inferred Mood & Russell's Circumplex Affective Mapping

The system infers the primary user's emotional state by evaluating dynamic motion signatures, step cadences, and sudden impact events through **Russell's Circumplex Model of Affect**.

### 14.1 Arousal Estimation (High vs Low Energy)
Arousal ($A$) is modeled using step frequency and active vibration energy:
1.  **Gait Cadence Contribution ($A_{bpm}$):** Derived from the average beats-per-minute (BPM) of gait entities compared to a baseline of $75\text{ BPM}$:
    $$A_{bpm} = \max\left(-1.0, \, \min\left(1.0, \, \frac{\text{BPM}_{avg} - 75.0}{30.0}\right)\right)$$
2.  **Chassis Vibration Contribution ($A_{activity}$):** Scaled using root-mean-square (RMS) linear acceleration:
    $$A_{activity} = \min(1.0, \, \text{RMS} \cdot 10.0)$$

*   **Total Arousal ($A$):** Weighted combination of gait frequency and structural vibration:
    $$A = 0.6 \cdot A_{bpm} + 0.4 \cdot A_{activity} \in [-0.6, \, 1.0]$$

### 14.2 Valence Estimation (Positive vs Negative Pleasure)
Valence ($V$) evaluates the smoothness of device movement and physical stress:
*   **Stress Penalties ($S_{penalty}$):** Sudden shock impacts or erratic signals reduce valence:
    *   If peak dynamic linear G-force $> 0.5\text{ g}$: Subtracts $0.3$
    *   If acceleration signal kurtosis $> 6.0$: Subtracts $0.3$
    *   If lid angle rotation speed $> 50.0\text{ deg/s}$: Subtracts $0.2$
    *   If logic board solder fatigue probability $> 0.3$: Subtracts $0.2$
*   **Smooth Bonuses ($S_{bonus}$):** Smooth periodic motion increases valence:
    *   If periodicity coefficient of variation $\text{CV} < 0.2$: Adds $0.4$
    *   If spectral balance $< 0.0$ (low-frequency vibration dominant): Adds $0.3$
    *   If periodic step cadences are detected with zero stress penalties: Adds $0.3$

*   **Total Valence ($V$):** Clamped strictly between positive and negative limits:
    $$V = \max(-1.0, \, \min(1.0, \, S_{bonus} + S_{penalty}))$$

### 14.3 Russell Affect Quadrant Mapping
Valence ($V$) and Arousal ($A$) are mapped onto the four emotional circumplex quadrants:
*   **Calm/Relaxed ($V \ge 0, A < 0$):** $S_{calm} = \max(0, V) \cdot \max(0, -A)$
*   **Excited/Joyful ($V \ge 0, A \ge 0$):** $S_{excited} = \max(0, V) \cdot \max(0, A)$
*   **Tired/Bored ($V < 0, A < 0$):** $S_{tired} = \max(0, -V) \cdot \max(0, -A)$
*   **Anxious/Frustrated ($V < 0, A \ge 0$):** $S_{anxious} = \max(0, -V) \cdot \max(0, A)$

Using a baseline epsilon ($\epsilon = 0.1$) to prevent division-by-zero, the final quadrant probabilities are resolved:
$$\text{Total} = S_{calm} + S_{excited} + S_{tired} + S_{anxious} + 4\epsilon$$
$$\text{Prob}(\text{Calm/Relaxed}) = \frac{S_{calm} + \epsilon}{\text{Total}}$$
$$\text{Prob}(\text{Excited/Joyful}) = \frac{S_{excited} + \epsilon}{\text{Total}}$$
$$\text{Prob}(\text{Tired/Bored}) = \frac{S_{tired} + \epsilon}{\text{Total}}$$
$$\text{Prob}(\text{Anxious/Frustrated}) = \frac{S_{anxious} + \epsilon}{\text{Total}}$$

---

## 15. Inertial Pedometer and Gait Filtering Engine

The GNAT Ada daemon implements a real-time, stream-based bandpass pedometer to isolate walking steps and human walking cadences from high-frequency structural vibrations.

### 15.1 Dynamic Acceleration Isolate
Linear dynamic acceleration $\mathbf{a}_{dyn} = (A_{x\_D}, \, A_{y\_D}, \, A_{z\_D})$ in world frame is obtained by applying the orientation quaternion to raw IMU readings and subtracting calibrated gravity:
$$\mathbf{a}_{dyn} = \mathbf{R} \cdot (\mathbf{a}_{raw} - \mathbf{v} \cdot \text{Calibrated\_G}) \cdot 9.80665 \quad (\text{m/s}^2)$$

### 15.2 High-Pass Velocity Integration (0.5Hz Cutoff)
To isolate human movements ($0.5\text{ Hz}$ to $3.0\text{ Hz}$) and eliminate integration drift, the dynamic acceleration is integrated into a high-pass filtered velocity vector $\mathbf{v}_{HP}$:
$$RC_{HP} = \frac{1}{2\pi \cdot 0.5}, \quad \alpha_{HP} = \frac{RC_{HP}}{RC_{HP} + dt}$$
$$v_{HP\_i}[n] = \alpha_{HP} \cdot (v_{HP\_i}[n-1] + a_{dyn\_i} \cdot dt)$$
Where $i \in \{x, y, z\}$ and $dt$ represents the precise loop interval timestamp delta.

### 15.3 Low-Pass Magnitude Smoothing (3.0Hz Cutoff)
1.  **Velocity Magnitude:** The absolute magnitude of the high-pass velocity vector is calculated:
    $$V_{mag} = \|\mathbf{v}_{HP}\| = \sqrt{v_{HP\_x}^2 + v_{HP\_y}^2 + v_{HP\_z}^2}$$
2.  **Smoothing Filter:** High-frequency muscle jitters and chassis noise are smoothed out using a 3.0Hz low-pass filter:
    $$RC_{LP} = \frac{1}{2\pi \cdot 3.0}, \quad \alpha_{LP} = \frac{dt}{RC_{LP} + dt}$$
    $$V_{smooth}[n] = \alpha_{LP} \cdot V_{mag} + (1.0 - \alpha_{LP}) \cdot V_{smooth}[n-1]$$

### 15.4 Online Peak Step Detection and Lockout
The smoothed velocity magnitude is processed through an online stream-based state machine:
```
           (V_smooth > 0.02)
   +------------------------------+
   |                              |
   v                              |
[Excursion rising]                |
   | (Track peak & Peak_Time)     |
   |                              |
   v                              |
(V_smooth <= 0.02)                |
   |                              |
   v                              |
[Excursion falling] --------------+
   | (Check Peak_Candidate > 0.02)
   v
[Step Candidate Lockout check]
   | (Time - Last_Step_Time >= 0.35s)
   +---> [Steps = Steps + 1] ---> [Reset Peak_Candidate = 0.0]
```
*   **Walking Threshold:** A step excursion begins when $V_{smooth} > 0.02\text{ m/s}$. During the rising phase, the daemon tracks the maximum peak value and its timestamp:
    $$\text{Peak\_Candidate} = \max\left(\text{Peak\_Candidate}, \, V_{smooth}\right)$$
    $$\text{Peak\_Time} = \text{Timestamp}$$
*   **Falling Edge Trigger:** When $V_{smooth} \le 0.02\text{ m/s}$ (dropping back below the walking threshold), the system evaluates the candidate step:
    *   **Lockout Dead-Time:** A valid step is registered only if the elapsed time since the previous step is at least $350\text{ milliseconds}$ ($0.35\text{ seconds}$), preventing false double-triggers:
        $$\text{Steps} = \text{Steps} + 1, \quad \text{Last\_Step\_Time} = \text{Peak\_Time}$$
    *   **Reset:** The excursion trackers are reset to zero to capture the next step.

---

## 16. Dynamic Gravity Calibration and Microgravity Adaptation

The GNAT Ada daemon continuously calibrates the baseline local gravitational acceleration vector magnitude ($\text{Calibrated\_G}$) to account for geographic anomalies, elevation, or custom sensor scale biases.

### 16.1 Online IIR Calibration Filter
When the device is detected to be extremely static (rotation velocity magnitude $\|\boldsymbol{\omega}\| < 0.5\text{ deg/s}$):
1.  **Raw Acceleration Magnitude:**
    $$A_{raw\_mag} = \sqrt{a_x^2 + a_y^2 + a_z^2} \quad (\text{g})$$
2.  **Slow Adaptation (EMA Filter):** The system adapts $\text{Calibrated\_G}$ (initially $1.0\text{ g}$) using a $10$-second time constant IIR filter at $100\text{ Hz}$ ($\alpha = 0.001$):
    $$\text{Calibrated\_G}_{new} = 0.999 \cdot \text{Calibrated\_G}_{old} + 0.001 \cdot A_{raw\_mag}$$

### 16.2 Behavior in Microgravity (Space and Freefall)
In orbit or freefall:
*   The raw accelerometer registers zero linear forces: $A_{raw\_mag} \approx 0.0\text{ g}$.
*   When the device is not rotating ($\|\boldsymbol{\omega}\| < 0.5\text{ deg/s}$), the calibration loop slowly drives the local gravity parameter to zero:
    $$\text{Calibrated\_G} \to 0.0\text{ g}$$
*   **Zero-Gravity Auto-Tuning:** With $\text{Calibrated\_G} = 0.0$, the linear gravity subtraction formula becomes:
    $$\mathbf{a}_{dyn} = \mathbf{a}_{raw} - \mathbf{v} \cdot \text{Calibrated\_G} \equiv \mathbf{a}_{raw}$$
    This automatically disables gravity subtraction in space, enabling the system to perfectly track raw thruster burns and orbital accelerations directly without mathematical distortions!

---

## 17. QUATERN (Orientation Quaternion)

The orientation state block `"q"` maintains the device's 3D spatial attitude:
*   **Attitude Quaternion ($\mathbf{q}$):** Maintained as a 4-dimensional unit vector $\mathbf{q} = (Q_w, \, Q_x, \, Q_y, \, Q_z)$ by the Mahony complementary filter.
*   **Avoidance of Gimbal Lock:** By performing rotations using quaternions rather than Euler angles (Pitch, Roll, Yaw), the system preserves clean spatial attitude tracking through full 360-degree rotations in all axes, avoiding mathematical singularities.

---

## 18. Micro-Odometer (`odometer_30m`)

The sliding-window micro-odometer `"odometer_30m"` calculates the straight-line spatial displacement range of the device:
*   **30-Minute Sliding Window Queue:** A double-ended queue tracks relative Cartesian position coordinates $\mathbf{Pos} = (X, Y, Z)$ over the last 1800 seconds (30 minutes).
*   **Euclidean Displacement Distance:**
    $$\text{Odometer}_{30m} = \sqrt{(X_{curr} - X_{old})^2 + (Y_{curr} - Y_{old})^2 + (Z_{curr} - Z_{old})^2} \quad (\text{meters})$$
    *   Where $\mathbf{Pos}_{old}$ is the oldest coordinates sample stored at the start of the 30-minute window queue. This tracks the micro-displacement boundary range of the user.

---

## 19. CARDINAL Compass Headings (`compass_dir`)

The cardinal direction `"compass_dir"` translates geographic yaw/heading degrees into human-scannable 16-point wind directions:
*   **Heading Angle Range:** $\text{Heading} \in [0.0^\circ, \, 360.0^\circ)$ where $0.0^\circ$ corresponds to True North.
*   **16-Point Cardinal Index Mapping:**
    $$ix = \operatorname{floor}\left( \frac{\text{Heading} + 11.25}{22.5} \right)$$
    $$\text{Compass\_Dir} = \text{dirs}[ix \pmod{16}]$$
*   **Directions List:**
    $$\text{dirs} = \{ \text{N, NNE, NE, ENE, E, ESE, SE, SSE, S, SSW, SW, WSW, W, WNW, NW, NNW} \}$$

---

## 20. Localized METAR & TAF Soft-Sensor Synthesis

The sidecar dynamically generates standardized weather reports (METAR and TAF) for the local vehicle's position by synthesizing hard physical sensors with soft virtual sensors.

### 20.1 Hard Sensor vs. Soft Sensor Architecture
*   **Hard Physical Sensors:** Direct hardware measurements, such as logic board barometric pressure transducers ($P_{ambient}$) and ambient thermal resistor couples ($T_{ambient}$).
*   **Soft Virtual Sensors:** Real-time software models that calculate environmental attributes that are not directly measurable, such as:
    *   **Magnus-Tetens Dew Point ($T_{dewpoint}$)**
    *   **Dew Point Spread ($\Delta T_{spread} = T_{ambient} - T_{dewpoint}$)**
    *   **2D Wind Field Spatial Pressure Gradient Solver ($V_{wind}$, $\theta_{wind}$)**

### 20.2 METAR String Structuring and Formulation
A typical generated report matches standard meteorological notation:
$$\text{METAR EARU } [Time] \quad [Wind] \quad [Visibility] \quad [Clouds] \quad [Temp/DP] \quad [Altimeter]$$

1.  **Time Stamp:**
    Formatted in UTC as `DDHHMMZ` (e.g. `171214Z` for day 17 at 12:14 UTC).
2.  **Wind Velocity (`dddssKT`):**
    *   **Soft Sensor Source:** Solves the horizontal pressure gradients across the 2D wind grid to yield median wind vectors $v_x$ and $v_y$.
    *   **Angle Conversion ($\theta_{wind}$):** Converts vectors to wind heading degrees, rounded to the nearest $10^\circ$:
        $$\theta_{wind} = \operatorname{round}\left(\frac{\operatorname{atan2}(-v_x, -v_y) \cdot 180 / \pi}{10}\right) \cdot 10$$
    *   **Speed Conversion ($V_{kts}$):** Converts m/s to knots:
        $$V_{kts} = \sqrt{v_x^2 + v_y^2} \cdot 1.94384$$
    *   **Formatting:** Formatted as `f"{wind_dir_rounded:03d}{wind_speed_kts:02d}KT"` if $V_{kts} \ge 1.0$, else `"00000KT"` (calm).
3.  **Visibility ($Vis$ in Statute Miles - SM):**
    *   **Soft Sensor Source:** Determined as a function of the dew point spread:
        $$\text{Visibility} = \begin{cases} 
        \text{"10SM"} & \text{if } \Delta T_{spread} > 3.0\text{ K} \quad (\text{Good Visibility}) \\
        \text{"3SM"} & \text{if } 1.0\text{ K} < \Delta T_{spread} \le 3.0\text{ K} \quad (\text{Moderate Misting}) \\
        \text{"1/2SM"} & \text{if } \Delta T_{spread} \le 1.0\text{ K} \quad (\text{Heavy Fog / High Condensation})
        \end{cases}$$
4.  **Cloud Cover ($Clouds$):**
    *   **Soft Sensor Source:** Classified dynamically based on the condensation profile:
        $$\text{Cloud\_Cover} = \begin{cases} 
        \text{"CLR"} & \text{if } \Delta T_{spread} \ge 10.0\text{ K} \quad (\text{Clear}) \\
        \text{"SCT035"} & \text{if } 5.0\text{ K} \le \Delta T_{spread} < 10.0\text{ K} \quad (\text{Scattered Clouds at 3500 ft}) \\
        \text{"BKN015"} & \text{if } 2.0\text{ K} \le \Delta T_{spread} < 5.0\text{ K} \quad (\text{Broken Ceiling at 1500 ft}) \\
        \text{"VV001"} & \text{if } \Delta T_{spread} < 2.0\text{ K} \quad (\text{Indefinite Ceiling, vertical visibility 100 ft due to Fog})
        \end{cases}$$
5.  **Temperature & Dew Point ($Temp/DP$):**
    *   **Hard Sensor Source:** Read from MacBook internal thermal registers ($T_{c}$ in Celsius).
    *   **Soft Sensor Source:** Dew point temperature in Celsius ($DP_{c}$):
        $$\text{Temp/DP} = \begin{cases} 
        T_{c} \text{ / } DP_{c} & \text{if } T_{c} \ge 0^\circ\text{C} \\
        \text{"M"} |T_{c}| \text{ / "M"} |DP_{c}| & \text{if } T_{c} < 0^\circ\text{C} \quad (\text{"M" stands for Minus})
        \end{cases}$$
6.  **Altimeter Setting ($Altimeter$):**
    *   **Hard Sensor Source:** Formatted from the barometric transducer pressure reading ($P_{hPa}$):
        $$\text{Altimeter} = \frac{P_{hPa}}{33.8639} \quad (\text{inHg})$$
    *   **Formatting:** Exposed as `"A"` followed by altimeter inHg multiplied by 100 (e.g. `A2992`).

### 20.3 TAF Forecast Generation
The terminal aerodrome forecast (TAF) is projected 24 hours forward based on atmospheric trend metrics:
$$\text{TAF EARU } [Time] \quad [Period] \quad [Wind] \quad [Visibility] \quad [Clouds] \quad [Trend\_Modifiers]$$
*   **Trend Modifier rules:**
    *   **Trend Modifier rules:**
        *   If barometric pressure tendency drops rapidly ($\Delta P < -0.2\text{ hPa/hr}$): Appends a temporary rain modifier `TEMPO [Time] 2SM -RA BR BKN010` (predicting light rain and mist).
        *   If the dew point spread is very narrow ($\Delta T_{spread} < 3.0\text{ K}$): Appends a becoming fog modifier `BECMG [Time] 1SM FG VV001` (predicting rising morning fog).

---

## 21. 2D Spatial Wind Field Gradient and Head-Up Grid Mapping

The system constructs a dynamic $7 \times 7$ grid wind field map (`grid_7x7_10m`) rotated to face the device's current heading direction (Head-Up). This allows real-time visual monitoring of wind patterns, local gusts, and pressure fronts.

### 21.1 Vector Wind Physics
The solver relates world ground velocity ($\mathbf{V}_g$) and apparent airspeed magnitude ($V_a$):
*   **Dynamic Apparent Airpressure ($q$):** Corrected using the stationary barometric offset $P_{offset}$:
    $$q = \max\left(0, \, P_{ambient} - (P_{static} + P_{offset})\right) \cdot 100.0 \quad (\text{Pa})$$
*   **Indicated Apparent Airspeed ($V_a$):**
    $$V_a = \sqrt{\frac{2 \cdot q}{\rho}} \quad (\text{m/s})$$
*   **Wind Vector Average Estimation ($\mathbf{W}$):** Resolved over a rolling history weighted by ground speed to filter out stationary noise:
    $$\mathbf{W} = \frac{\sum \mathbf{V}_g \cdot \left(1.0 - \frac{V_a}{\|\mathbf{V}_g\|}\right) \cdot \|\mathbf{V}_g\|}{\sum \|\mathbf{V}_g\|} \quad (\text{m/s})$$

### 21.2 Inverse Distance Weighting (IDW) Spatial Interpolation
To evaluate wind conditions at a target coordinate $\mathbf{x} = (x, \, y, \, z)$, the system applies Numba-optimized IDW interpolation over all localized coordinates $\mathbf{p}_i = (x_i, \, y_i, \, z_i)$ stored within the 1-meter spatial tile structure:
1.  **Distance Filter:** Skip samples exceeding the search radius ($R_{search} = 30.0\text{ m}$):
    $$d_i = \|\mathbf{p}_i - \mathbf{x}\| = \sqrt{(x_i - x)^2 + (y_i - y)^2 + (z_i - z)^2} \le R_{search}$$
2.  **IDW Weighting ($w_i$):**
    $$w_i = \frac{1}{(d_i + 0.5)^2}$$
3.  **Weighted Interpolation Integration:**
    $$vw_i = \|\mathbf{V}_{g\_i}\| \cdot w_i$$
    $$\mathbf{W}(\mathbf{x}) = \frac{\sum \mathbf{V}_{g\_i} \cdot \left(1.0 - \frac{V_{a\_i}}{\|\mathbf{V}_{g\_i}\|}\right) \cdot vw_i}{\sum vw_i} \quad (\text{m/s})$$
    $$P(\mathbf{x}) = \frac{\sum P_i \cdot w_i}{\sum w_i} \quad (\text{hPa}), \quad T(\mathbf{x}) = \frac{\sum T_i \cdot w_i}{\sum w_i} \quad (\text{Kelvin})$$

### 21.3 Rotated Head-Up Grid Generation
To orient the wind field map relative to the vehicle's yaw direction (Head-Up), grid points are rotated dynamically around the center coordinate $\mathbf{x}_{center} = (C_x, \, C_y, \, C_z)$ given heading angle $\theta_{rad}$:
*   **Grid Specs:** $7 \times 7$ dimensions (`size = 7`) and a $10.0\text{ meter}$ scale resolution (`step = 10.0`).
*   **Rotated Grid Point Calculations:** For indices $i, j \in [0, 6]$:
    *   Compute local relative Cartesian offsets:
        $$l_x = \left(i - 3\right) \cdot 10.0, \quad l_y = \left(3 - j\right) \cdot 10.0 \quad (\text{meters})$$
    *   Rotate offsets into world coordinates:
        $$t_x = C_x + l_x \cdot \cos\theta_{rad} + l_y \cdot \sin\theta_{rad}$$
        $$t_y = C_y - l_x \cdot \sin\theta_{rad} + l_y \cdot \cos\theta_{rad}$$
    *   **Interpolate:** Interpolates wind, pressure, and temperature parameters at the coordinate point $(t_x, \, t_y, \, C_z)$ with search radius $R_{search} = 15.0\text{ m}$ to construct the Head-Up map.

---

## 22. Telemetry and Sensor Refresh Rates

To optimize CPU utilization, maintain system responsiveness, and extend battery longevity, the GNAT Ada daemon and the sidecar employ a multi-rate scheduler. Sensors are polled at rates calibrated to their physical bandwidth.

### 22.1 Hardware and Software Sensor Refresh Speed Table

| Sensor/Telemetry Metric | Update Frequency | Update Interval | Primary Purpose / Notes |
| :--- | :---: | :---: | :--- |
| **High-Res IMU (Accel & Gyro)** | $800.0\text{ Hz}$ | $1.25\text{ ms}$ | High-fidelity pedometer and physical seismic vibration sampling. |
| **Mahony Orientation Filter** | $100.0\text{ Hz}$ | $10.0\text{ ms}$ | Real-time world rotation quaternion ($\mathbf{q}$) attitude calculation. |
| **Seismic Event Detectors** | $100.0\text{ Hz}$ | $10.0\text{ ms}$ | Real-time CUSUM / STA-LTA structural anomaly threat tracking. |
| **HID Keystroke/Mouse Idle Scan** | $10.0\text{ Hz}$ | $100.0\text{ ms}$ | Human inactivity detection (`nonHumanInputHIDIdle`). |
| **SMC Battery Charging Status** | $0.20\text{ Hz}$ | $5.0\text{ s}$ | Detect power plug connections and battery charge mode transitions. |
| **2D Wind Field Grid Mapping** | $0.10\text{ Hz}$ | $10.0\text{ s}$ | Re-calculate spatial pressure gradients and Head-Up grid interpolation. |
| **Apple Smart Battery State** | $0.0167\text{ Hz}$ | $60.0\text{ s}$ | Dynamic capacity, design limit, and battery health percentage updates. |
| **macOS pmset Registry Query** | $0.0167\text{ Hz}$ | $60.0\text{ s}$ | Extract power source properties and system-wide sleep indicators. |
| **External Meteorology API** | $0.00027\text{ Hz}$ | $3600.0\text{ s}$ | 1-hour interval drift calibration values for the pressure altimeter. |
| **CoreLocation GPS Query** | *Dynamic* | *Dynamic* | Sleep intervals are scaled relative to device ground speed $V_{mag}$: |
| *   *Stationary ($V_{mag} = 0.0\text{ m/s}$)* | $0.0333\text{ Hz}$ | $30.0\text{ s}$ | Conserves battery power while stationary. |
| *   *Walking ($V_{mag} = 1.0\text{ m/s}$)* | $0.0667\text{ Hz}$ | $15.0\text{ s}$ | Tracks human walking trajectories and speeds. |
| *   *In Transport ($V_{mag} \ge 2.0\text{ m/s}$)* | $0.2500\text{ Hz}$ | $4.0\text{ s}$ | Standard navigation tracking during transit. |

---

## Dedication & Acknowledgments

*   **Special thanks to my lecturer, Mr. Agoes**, who has taken care of me and guided my engineering mindset with utmost dedication.
*   **Deep appreciation to the book *Compressible Flow* by John D. Anderson**, which taught me a single, deeply valuable, and universal scientific paradigm: 
    > *"If you have one, then you can find many."*
*   **The final nail on the sailing boat:** To **Mr. Felix**, whose wisdom and reminder echo constantly:
    > *"This world doesn't belong to, nor side with, people with excuses."*
*   **To my friend, Ol' Akhsan**, who keeps mocking me as a "Hacker." Well... let's make that wish a reality.
*   **To my Pop**, who always pushed me, holding high expectations for me to be instantly ready and always hot-to-go within ~5 seconds (living in that true "smartphone paradigm"). Thank you for pushing my limits.
*   **To the inventors and creators of the Ada and SPARK programming languages**—from **Jean Ichbiah** (who designed Ada under Honeywell Bull) and **Lady Ada Lovelace** (whose namesake and pioneering vision inspired it), to **Bernard Carré** (who pioneered the SPARK mathematical subset at Southampton University), and the modern engineering teams at **AdaCore** and **Capgemini Engineering**: thank you for guarding my runtime against the evils of segmentation faults and math domain errors, keeping me safe even beyond the static checks of Pyrefly.
*   **To the Gemini Language Model**, my tireless Language Model coding companion, for guiding my path and helping teach me the esoteric black magic of aerospace dynamics, real-time sensor fusion, and verified systems engineering.













