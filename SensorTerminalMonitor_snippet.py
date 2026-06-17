def update_significant_locations(self) -> None:
        if not hasattr(self, 'dwell_history'):
            self.dwell_history = []
            self.last_dwell_check = 0.0
            self.sig_loc_message = ""
            self.sig_loc_message_time = 0.0

        now = time.time()
        # Add entry every 5 seconds
        if now - self.last_dwell_check >= 5.0:
            self.last_dwell_check = now
            self.dwell_history.append((now, self.lat, self.lon, self.speed, len(self.wifi_devices), len(self.bt_devices)))

            # Filter to keep last 5 minutes (300 seconds)
            self.dwell_history = [item for item in self.dwell_history if now - item[0] <= 300]

            # Verify if we have at least 5 minutes of continuous data
            if len(self.dwell_history) >= 55: # close to 5 minutes of 5-sec entries
                t_start = self.dwell_history[0][0]
                t_end = self.dwell_history[-1][0]
                if t_end - t_start >= 280:
                    # Check conditions: LE present, quite wifi (>= 3), speed <= 30 knots
                    has_le = any(item[5] > 0 for item in self.dwell_history)
                    has_wifi = any(item[4] >= 3 for item in self.dwell_history)
                    low_speed = all(item[3] <= 30.0 for item in self.dwell_history)

                    # Calculate distance span in meters to verify staying within 5m radius
                    lats = [item[1] for item in self.dwell_history]
                    lons = [item[2] for item in self.dwell_history]

                    lat_min, lat_max = min(lats), max(lats)
                    lon_min, lon_max = min(lons), max(lons)

                    lat_avg = (lat_min + lat_max) / 2.0
                    dx = (lon_max - lon_min) * 111320.0 * math.cos(lat_avg * math.pi / 180.0)
                    dy = (lat_max - lat_min) * 111320.0
                    dist_span = math.sqrt(dx*dx + dy*dy)

                    if has_le and has_wifi and low_speed and dist_span <= 5.0:
                        sig_path = "/usr/local/EnvironmentalAwareReferentialUnit/save_state/significant_locations.json"
                        locs = []
                        if os.path.exists(sig_path):
                            try:
                                with open(sig_path, "r") as f:
                                    locs = json.load(f)
                            except Exception:
                                pass

                        # Check duplicate (within 10m of existing)
                        is_dup = False
                        for loc in locs:
                            plat = loc.get("latitude", 0.0)
                            plon = loc.get("longitude", 0.0)
                            p_lat_avg = (self.lat + plat) / 2.0
                            pdx = (self.lon - plon) * 111320.0 * math.cos(p_lat_avg * math.pi / 180.0)
                            pdy = (self.lat - plat) * 111320.0
                            pdist = math.sqrt(pdx*pdx + pdy*pdy)
                            if pdist <= 10.0:
                                is_dup = True
                                break

                        if not is_dup:
                            new_loc = {
                                "timestamp": datetime.datetime.now().isoformat(),
                                "latitude": self.lat,
                                "longitude": self.lon,
                                "avg_wifi_density": int(sum(item[4] for item in self.dwell_history) / len(self.dwell_history)),
                                "avg_ble_density": int(sum(item[5] for item in self.dwell_history) / len(self.dwell_history)),
                                "type": "User Anchor Base / Home Hub",
                                "description": "Dwell time > 5 min, low velocity (< 30 kts), strong local WiFi and BLE beacon anchors."
                            }
                            locs.append(new_loc)
                            try:
                                with open(sig_path, "w") as f:
                                    json.dump(locs, f, indent=4)
                                self.sig_loc_message = f"BASE STATION DETECTED & LOCKED: ({self.lat:.4f}, {self.lon:.4f})"
                                self.sig_loc_message_time = now
                                print(f"[ok] SIGNIFICANT LOCATION RECORDED: {new_loc}")
                            except Exception as e:
                                print(f"[!] Failed to save significant location: {e}")

    