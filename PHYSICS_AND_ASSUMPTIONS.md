# EARU & SMC: Physics, Constants, and System Assumptions

This document outlines the mathematical models and physical constants assumed within the EnvironmentalAwareReferentialUnit (EARU) and the SMC Demand Catcher Engine.

## 1. Atmospheric Physics (EcosystemEnvironmentReading)
*   **Ideal Gas Constant (Dry Air):** $R_{dry} = 287.05 \text{ J/(kg·K)}$.
*   **Specific Heat (Dry Air @ 300K):** $C_{p,dry} \approx 1005 \text{ J/(kg·K)}$.
*   **Dynamic $C_p$ Model:** $C_{p,dry}(T) = 1005 + 0.05 \cdot (T - 300)$.
*   **Moisture Adjustment:**
    *   $R_{humid} = R_{dry} \cdot (1 + 0.608 \cdot q)$
    *   $C_{p,humid} = C_{p,dry} \cdot (1 + 0.84 \cdot q)$
    *   Where $q$ is specific humidity derived via the **Bolton Equation** for saturation vapor pressure.
*   **Standard Sea Level Pressure:** $1013.25 \text{ hPa}$.
*   **Lapse Rate (ISA):** $0.0065 \text{ K/m}$ (used for pressure-altitude conversions up to 11km).

## 2. Hardware Proxies (MacBook Pro 14" M2 Pro - Amaryllis)
*   **Fan Volumetric Flow:** Assumed linear. $\dot{V} \approx (\text{RPM} / 6000) \cdot 0.007 \text{ m}^3/\text{s}$ per fan.
*   **Ambient Temperature Proxy:** Derived as $\min(TS0P, TS1P)$ (Palm Rest sensors).
*   **Inlet Temperature Proxy:** Derived as $\min(TaLW, TaRW)$ (Wrist Airflow sensors).
*   **Outlet Temperature Proxy:** Derived as $\max(TaLT, TaRT)$ (Top Airflow sensors).
*   **Heatflux Calculation:** $\dot{Q} = \rho \cdot \dot{V} \cdot C_p \cdot (T_{outlet} - T_{inlet})$.

## 3. Inertial Navigation & Motion
*   **Sampling Frequency ($f_s$):** $100 \text{ Hz}$.
*   **Standard Gravity ($g$):** $9.80665 \text{ m/s}^2$.
*   **Mahony Filter Gains:** $K_p = 2.0$, $K_i = 0.005$.
*   **Dead Reckoning Damping (ZUPT):** 
    *   Stationary: $0.90$ (10% velocity bleed per sample).
    *   Moving: $0.995$ (0.5% velocity bleed per sample).
*   **Earth Model:** Spherical approximation. $111,111 \text{ meters per degree latitude}$.

## 4. SMC Thermal Management Thresholds
*   **High Performance Activation:** $93^\circ\text{C}$ (TCMz/GPU) or $40 \text{ J/s}$ (System Power).
*   **Manual Fan Control Activation:** $86^\circ\text{C}$.
*   **Fan Overdrive ($10,100 \text{ RPM}$):** $\ge 95^\circ\text{C}$ or Persistent Anomaly.
*   **Survival Mode:** $\ge 60^\circ\text{C}$ Airflow (TaLP/TaRF).
*   **Battery Safety:** Target $39^\circ\text{C}$ via PID; Overdrive at $42^\circ\text{C}$.
