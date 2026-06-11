import mmap
import posix_ipc

try:
    shm = posix_ipc.SharedMemory("STATS_SHM")
    map_file = mmap.mmap(shm.fd, shm.size)
    shm.close_fd()

    # Header is 16 bytes.
    # CPU_Usage, Mem_Usage, Battery_Percent, Battery_State, V_Mag, Lid_Angle, Lid_Speed, Lux_Factor
    # Spectral(4), SMC_TaRT, SMC_TaRW, SMC_Tg0X, SMC_Ts0P, SMC_Ts1P, Power_W, Day_Power_Wh, Month_Power_Wh
    # Meter_Power_Wh, Est_Today_Wh, Bat_Design_Wh, Bat_Energy_Wh, Bat_Full_Wh, Bat_Health_Pct, Load_Avg_1
    # Load_Avg_5, Load_Avg_15, HID_Idle_ns(8 bytes), Uptime_System, Uptime_Earu

    # Total size: 16 (Header) + 26 * 4 (Float32) + 8 (HID) + 2 * 4 (Uptimes) = 16 + 104 + 8 + 8 = 136 bytes
    # But let's just dump the raw bytes

    data = map_file.read(136)
    print("Raw SHM Bytes:", data.hex())
except Exception as e:
    print("Error:", e)
