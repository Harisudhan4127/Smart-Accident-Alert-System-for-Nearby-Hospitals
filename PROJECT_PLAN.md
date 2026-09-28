# Smart Accident Alert System for Nearby Hospitals

 ## 1\. Project Overview

 The **Smart Accident Alert System for Nearby Hospitals** is an IoT-based accident detection and emergency notification system.

 The system uses an **ESP32**, an **ADXL345 three-axis accelerometer**, and a **SW-420 vibration sensor** to detect possible vehicle accidents.

 > **Change from the original plan.** This document originally specified an
 > **MPU6050**, which is a six-axis accelerometer *and* gyroscope. The
 > implementation uses an **ADXL345**, which is an accelerometer only. There is
 > therefore **no rotation-rate measurement anywhere in the system**, and nothing
 > downstream may assume one. Rotation is observed only as a change in the
 > direction of gravity. The two changes this forces are marked **[ADXL345]** at
 > each point they affect.

 When an accident is detected:

 1. ESP32 processes the sensor data.
2. ESP32 activates the buzzer and LED indicators.
3. ESP32 sends an accident event to an Android smartphone.
4. Android obtains the phone's GPS location.
5. The application sends the accident information to the cloud.
6. The application identifies nearby hospitals.
7. Emergency contacts can receive an emergency notification.
8. The accident location can be opened in Google Maps.
9. Accident information is stored in Firebase/Cloud.

---

 # 2\. Project Objectives

 ## Main Objectives

 - Detect possible vehicle accidents automatically.
- Reduce the time required to report an accident.
- Obtain accident location using the smartphone GPS.
- Send accident information through the Internet.
- Identify nearby hospitals.
- Notify predefined emergency contacts.
- Store accident records in the cloud.
- Provide a manual SOS button.
- Provide a mechanism to cancel false accident alerts.

---

 # 3\. System Architecture

```
                    VEHICLE
                       |
                       v
              +----------------+
              |     ESP32      |
              +-------+--------+
                      |
             +--------+--------+
             |                 |
             v                 v
        +---------+       +---------+
        | ADXL345 |       | SW-420  |
        +---------+       +---------+
             |                 |
             +--------+--------+
                      |
                Accident Logic
                      |
          +-----------+-----------+
          |           |           |
          v           v           v
       Buzzer       LEDs       OLED
                      |
                      v
             Bluetooth / Wi-Fi
                      |
                      v
             +----------------+
             |  Android App   |
             +-------+--------+
                     |
          +----------+----------+
          |          |          |
          v          v          v
         GPS      Internet    Maps
          |          |
          |          v
          |     +---------+
          +---->|Firebase |
                +---------+
                    |
          +---------+---------+
          |                   |
          v                   v
 Emergency Contacts     Nearby Hospitals
```

---

 # 4\. Hardware Requirements

 | No. | Component | Quantity | Purpose |
| --- | --- | --- | --- |
| 1 | ESP32 Development Board | 1 | Main controller |
| 2 | ADXL345 | 1 | Three-axis acceleration sensing (no gyroscope) **[ADXL345]** |
| 3 | SW-420 Vibration Sensor | 1 | Vibration/impact detection |
| 4 | Buzzer | 1 | Local accident warning |
| 5 | Emergency Push Button | 1 | Manual SOS/cancel |
| 6 | LED Indicators | 2–3 | System status |
| 7 | 220Ω Resistors | As required | LED current limiting |
| 8 | 1kΩ Resistors | As required | Signal/interface requirements |
| 9 | 0.96-inch OLED I²C | 1 | Display system status |
| 10 | Rechargeable Battery/Power Bank | 1 | Power source |
| 11 | Android Smartphone | 1 | GPS, Internet and application |
| 12 | Breadboard | 1 | Prototype |
| 13 | Jumper Wires | 1 set | Connections |
| 14 | On/Off Switch | 1 | Recommended |
| 15 | Enclosure | 1 | Recommended for final prototype |

---

 # 5\. Why GPS and GSM Modules Are Not Required

 The prototype uses the Android smartphone for:

 - GPS location
- Mobile Internet
- Emergency communication
- Maps
- Cloud communication

 Therefore, separate GPS and GSM modules are not required for the initial prototype.

 The communication architecture is:

```
ESP32
  |
  | Bluetooth
  v
Android Phone
  |
  | GPS + Mobile Internet
  v
Cloud / Emergency Services
```

 ### Important Limitation

 The smartphone must be:

 - Near the ESP32.
- Connected to the ESP32.
- Powered on.
- Able to obtain location.
- Connected to the Internet for cloud communication.

 A later version can add an independent GPS/GSM/LTE module if the system must operate without a smartphone.

---

 # 6\. Suggested ESP32 Pin Configuration

 The following is a suggested starting configuration.

 | Component | Pin | ESP32 GPIO |
| --- | --- | --- |
| ADXL345 | SDA | GPIO 21 |
| ADXL345 | SCL | GPIO 22 |
| ADXL345 | VCC | 3.3V (VS is **not** 5 V tolerant) |
| ADXL345 | GND | GND |
| ADXL345 | SDO | GND for `0x53`; 3V3 for `0x1D` **[ADXL345]** |
| OLED | SDA | GPIO 21 |
| OLED | SCL | GPIO 22 |
| OLED | VCC | 3.3V |
| OLED | GND | GND |
| SW-420 | OUT | GPIO 27 |
| Buzzer | Signal | GPIO 25 |
| Emergency Button | Signal | GPIO 26 |
| Green LED | Signal | GPIO 32 |
| Red LED | Signal | GPIO 33 |

> Verify the voltage requirements of each module before connecting it to the ESP32.

 The ADXL345 and OLED can share the same I²C bus. **[ADXL345]**

 The two addresses must differ: the accelerometer is `0x53` (or `0x1D` if SDO is
 tied high) and the OLED is `0x3C`. That is two devices; a third will not fit at
 the default addresses without an I²C multiplexer. The firmware probes `0x53`
 first and falls back to `0x1D`, and reports the address it settled on.

---

 # 7\. Hardware Block Design

 ## ADXL345 **[ADXL345]**

 The ADXL345 provides:

 - X-axis acceleration
- Y-axis acceleration
- Z-axis acceleration

 It is configured for **±16 g** at a **100 Hz** output rate, in `FULL_RES` mode,
 which pins the scale at 3.9 mg per LSB on every range.

 The accelerometer is primarily used for detecting sudden changes in motion.

 **What it does not provide: rotation rate.** The six gyroscope axes the original
 MPU6050 specified are gone, and no rotation rate is derived from the
 accelerometer — differentiating acceleration to manufacture one would produce a
 number that looks physical and is not. A rollover is instead detected from a
 change in the *direction* of the measured gravity vector, which is weaker: it
 only sees a vehicle that ends up tilted, not one that spins and returns to
 level. **[ADXL345]**

 ## SW-420

 The SW-420 provides a simple vibration signal.

 It should be used as supporting information rather than the only accident detector.

 ## ESP32

 The ESP32:

 - Reads sensors.
- Processes accident conditions.
- Controls LEDs.
- Controls buzzer.
- Updates OLED.
- Communicates with the smartphone.

 ## OLED

 Example display:

```
SMART ACCIDENT
SYSTEM

Status: ACTIVE

BT: CONNECTED
GPS: PHONE
```

 During an event:

```
WARNING!

ACCIDENT
DETECTED

CANCEL?
```

---

 # 8\. Accident Detection Algorithm

 The system should not trigger an emergency alert simply because the vibration sensor activates.

 A basic algorithm:

```
START
  |
  v
Initialize sensors
  |
  v
Read ADXL345
  |
  v
Read SW-420
  |
  v
Calculate acceleration
  |
  v
Acceleration above threshold?
  |
  +---- NO ----> Continue monitoring
  |
 YES
  |
  v
Check vibration signal
  |
  v
Check additional conditions
  |
  v
Possible accident
  |
  v
Activate buzzer/LED
  |
  v
Send alert to Android
  |
  v
Start cancellation countdown
  |
  +---- User cancels ----> Cancel event
  |
  v
Confirm accident
  |
  v
Send emergency event
```

---

 # 9\. False Alarm Protection

 False alarms are an important problem.

 Possible causes include:

 - Potholes
- Sudden braking
- Dropping the device
- Normal vehicle vibration
- Rough roads

 Therefore, use multiple conditions.

 Example:

```
High acceleration
        +
Vibration detected
        +
Sudden orientation/motion change
        |
        v
Possible accident
```

 The exact thresholds should be determined experimentally during testing.

---

 # 10\. Emergency Button

 The emergency button should support manual emergency activation.

 Example:

```
Button pressed
      |
      v
ESP32 detects button
      |
      v
Send SOS event
      |
      v
Android application
      |
      v
Get GPS location
      |
      v
Send emergency notification
```

 The button can also be used to cancel a false automatic accident alert, depending on the final UI design.

---

 # 11\. Android Application

 ## Main Features

 The Android application should provide:

 - ESP32 connection
- Accident event reception
- GPS location
- Internet communication
- Emergency contacts
- Hospital search
- Google Maps integration
- Firebase integration
- Accident history
- Emergency notifications
- Manual SOS

---

 # 12\. Android Application Screens

 ## Screen 1 — Splash Screen

```
SMART ACCIDENT
ALERT SYSTEM

Loading...
```

 ## Screen 2 — Home

```
SMART ACCIDENT ALERT

Device:
CONNECTED

GPS:
AVAILABLE

Internet:
CONNECTED

[ TEST ALERT ]

[ SOS ]

[ SETTINGS ]

[ HISTORY ]
```

 ## Screen 3 — Accident Alert

```
⚠ POSSIBLE ACCIDENT

Accident detected!

Location:
Waiting for GPS...

Alert will be sent in:

10 seconds

[ I'M SAFE ]
```

 ## Screen 4 — Location

```
ACCIDENT LOCATION

Latitude:
12.xxxxxx

Longitude:
79.xxxxxx

Accuracy:
10 meters

[ OPEN MAP ]

[ FIND HOSPITALS ]
```

 ## Screen 5 — Nearby Hospitals

```
NEARBY HOSPITALS

1. Hospital A
   1.2 km

2. Hospital B
   2.4 km

3. Hospital C
   3.1 km

[ OPEN MAP ]
```

 ## Screen 6 — Emergency Contacts

```
EMERGENCY CONTACTS

Mother
+91 XXXXX XXXXX

Father
+91 XXXXX XXXXX

Friend
+91 XXXXX XXXXX

[ ADD CONTACT ]
```

 ## Screen 7 — Accident History

```
ACCIDENT HISTORY

27/09/2026
Possible Accident
Location Available

25/09/2026
Manual SOS
Resolved
```

---

 # 13\. Android ↔ ESP32 Communication

 The initial prototype can use Bluetooth/BLE.

 Example communication messages:

```
DEVICE_CONNECTED
```

```
HEARTBEAT
```

```
ACCIDENT_DETECTED
```

```
MANUAL_SOS
```

```
ALERT_CANCELLED
```

```
ALERT_CONFIRMED
```

 A simple event flow:

```
ESP32
  |
  | ACCIDENT_DETECTED
  v
Android
  |
  | Get GPS
  v
Location
  |
  | Upload
  v
Firebase
```

---

 # 14\. GPS Location

 The Android application obtains:

 - Latitude
- Longitude
- Accuracy
- Timestamp

 Example:

```
Latitude: 12.345678
Longitude: 79.123456
Accuracy: 8 meters
Timestamp: 2026-09-27 10:30:00
```

 The coordinates can then be used to:

 - Display the accident position.
- Open Google Maps.
- Search for nearby hospitals.
- Store the event in Firebase.
- Send the location to emergency contacts.

---

 # 15\. Google Maps

 The application should provide a button:

```
[ OPEN ACCIDENT LOCATION ]
```

 This opens the accident coordinates in a map application.

 The location format can be:

```
https://www.google.com/maps/search/?api=1&query=LATITUDE,LONGITUDE
```

 Do not hard-code the latitude and longitude.

 Generate them dynamically from the phone's current GPS location.

---

 # 16\. Nearby Hospital System

 The hospital feature should work as follows:

```
Accident Location
       |
       v
Latitude + Longitude
       |
       v
Hospital Search
       |
       v
Nearby Hospital List
       |
       +---- Name
       +---- Address
       +---- Distance
       +---- Phone
       +---- Map Location
```

 For the first prototype, a predefined hospital database can be used.

 For a more advanced implementation, use a suitable maps/places service.

---

 # 17\. Firebase/Cloud Design

 A simple Firestore structure:

```
users
  |
  +-- userId
       |
       +-- name
       +-- phone
       +-- vehicleNumber
       +-- emergencyContacts

accidents
  |
  +-- accidentId
       |
       +-- userId
       +-- latitude
       +-- longitude
       +-- accuracy
       +-- timestamp
       +-- impactValue
       +-- status
       +-- deviceId

hospitals
  |
  +-- hospitalId
       |
       +-- name
       +-- address
       +-- latitude
       +-- longitude
       +-- phone
```

---

 # 18\. Accident Status

 Use a simple status system:

```
DETECTED
```

```
CANCELLED
```

```
CONFIRMED
```

```
ALERT_SENT
```

```
RESOLVED
```

 Example:

```
DETECTED
   |
   +---- CANCELLED
   |
   +---- CONFIRMED
             |
             v
         ALERT_SENT
             |
             v
          RESOLVED
```

---

 # 19\. Emergency Notification Flow

```
Accident Detected
       |
       v
Android App
       |
       v
Get GPS
       |
       v
User confirmation/countdown
       |
       v
Create accident record
       |
       +----------------+
       |                |
       v                v
Emergency          Nearby Hospital
Contacts           Information
       |
       v
Location + Time + Emergency Message
```

---

 # 20\. Example Emergency Message

```
EMERGENCY ALERT

A possible accident has been detected.

Time:
27/09/2026 10:30 AM

Location:
12.345678, 79.123456

Please check the person's condition.

Open location:
Google Maps
```

 For the prototype, use configured emergency contacts rather than assuming hospitals will automatically receive or respond to the alert.

---

 # 21\. Software Development Tools

 ## ESP32

 Recommended:

 - Arduino IDE
- ESP32 board support
- C/C++
- ADXL345 library (Adafruit ADXL345 + Adafruit Unified Sensor)
- OLED library
- Bluetooth/BLE support

 ## Android

 Recommended:

 - Android Studio
- Kotlin
- Android SDK
- Bluetooth/BLE APIs
- Location APIs
- Firebase SDK
- Maps integration

 ## Cloud

 Recommended:

 - Firebase Authentication
- Cloud Firestore
- Firebase Cloud Messaging where appropriate
- Firebase security rules

---

 # 22\. Suggested Project Folder Structure

```
smart-accident-alert/
│
├── README.md
├── PROJECT_PLAN.md
├── LICENSE
│
├── hardware/
│   ├── circuit/
│   ├── diagrams/
│   ├── pinout.md
│   └── bill-of-materials.md
│
├── esp32/
│   ├── src/
│   │   ├── main.cpp
│   │   ├── accident_detection.cpp
│   │   ├── accident_detection.h
│   │   ├── bluetooth.cpp
│   │   ├── bluetooth.h
│   │   ├── display.cpp
│   │   ├── display.h
│   │   └── sensors.cpp
│   │
│   └── README.md
│
├── android/
│   ├── app/
│   ├── README.md
│   └── ...
│
├── firebase/
│   ├── firestore-rules.txt
│   └── database-structure.md
│
├── docs/
│   ├── architecture.md
│   ├── testing.md
│   └── user-manual.md
│
└── tests/
    ├── sensor-tests/
    ├── bluetooth-tests/
    └── android-tests/
```

---

 # 23\. Development Phases

 ## Phase 1 — Hardware Setup

 Tasks:

 - Connect ESP32.
- Connect ADXL345.
- Connect SW-420.
- Connect OLED.
- Connect buzzer.
- Connect LEDs.
- Connect emergency button.
- Verify power supply.

 Deliverable:

```
Working ESP32 prototype
```

---

 ## Phase 2 — Sensor Testing

 Tasks:

 - Read ADXL345 acceleration on all three axes.
- ~~Read gyroscope values.~~ Removed: the ADXL345 has no gyroscope, and no
  substitute is to be derived. **[ADXL345]**
- Read SW-420.
- Display values on Serial Monitor.
- Display status on OLED.

 Deliverable:

```
Working sensor monitoring
```

---

 ## Phase 3 — Accident Detection

 Tasks:

 - Calculate acceleration magnitude.
- Establish normal-motion values.
- Establish experimental accident threshold.
- Combine ADXL345 and SW-420.
- Add false-alarm protection.
- Add countdown/cancellation.

 Deliverable:

```
Accident detection prototype
```

---

 ## Phase 4 — ESP32 Alert System

 Tasks:

 - Buzzer activation.
- LED warning.
- OLED warning.
- Manual SOS.
- Accident event generation.

 Deliverable:

```
Complete ESP32 alert device
```

---

 ## Phase 5 — Bluetooth Communication

 Tasks:

 - Pair/connect ESP32 with Android.
- Send test messages.
- Send accident event.
- Send manual SOS.
- Send cancellation event.

 Deliverable:

```
ESP32 ↔ Android communication
```

---

 ## Phase 6 — Android GPS

 Tasks:

 - Request location permission.
- Obtain GPS coordinates.
- Display latitude/longitude.
- Display GPS accuracy.
- Store timestamp.

 Deliverable:

```
Android GPS module
```

---

 ## Phase 7 — Firebase

 Tasks:

 - Create Firebase project.
- Configure Android application.
- Create Firestore database.
- Store users.
- Store emergency contacts.
- Store accidents.
- Read accident history.

 Deliverable:

```
Cloud accident database
```

---

 ## Phase 8 — Hospital Search

 Tasks:

 - Obtain accident location.
- Search for nearby hospitals.
- Display hospital names.
- Display distance.
- Display addresses.
- Open hospital location on map.

 Deliverable:

```
Nearby hospital feature
```

---

 ## Phase 9 — Emergency Notifications

 Tasks:

 - Add emergency contacts.
- Generate emergency message.
- Send notification.
- Include location.
- Include accident time.
- Include map location.

 Deliverable:

```
Emergency notification system
```

---

 ## Phase 10 — Complete Integration

 Combine:

```
ESP32
  +
Sensors
  +
Bluetooth
  +
Android
  +
GPS
  +
Firebase
  +
Hospital Search
  +
Emergency Notification
```

 Deliverable:

```
Complete Smart Accident Alert System
```

---

 # 24\. Testing Plan

 ## Hardware Tests

 - [ ] ESP32 power test
- [ ] ADXL345 test (all three axes; no gyro test — there is no gyro)
- [ ] SW-420 test
- [ ] OLED test
- [ ] Buzzer test
- [ ] LED test
- [ ] Button test
- [ ] Battery test

 ## Accident Detection Tests

 - [ ] Normal movement
- [ ] Sudden braking simulation
- [ ] Controlled vibration
- [ ] Controlled impact simulation
- [ ] Device drop test
- [ ] Pothole simulation
- [ ] False alarm cancellation

 ## Communication Tests

 - [ ] Bluetooth connection
- [ ] Bluetooth disconnection
- [ ] Accident message
- [ ] SOS message
- [ ] Cancellation message

 ## Android Tests

 - [ ] GPS permission
- [ ] GPS unavailable
- [ ] Internet unavailable
- [ ] Hospital search
- [ ] Map opening
- [ ] Emergency contact
- [ ] Accident history

 ## Cloud Tests

 - [ ] Firebase connection
- [ ] Accident upload
- [ ] Accident retrieval
- [ ] Authentication
- [ ] Security rules

---

 # 25\. Failure Handling

 The application should handle failures gracefully.

 ## Bluetooth disconnected

 Display:

```
ESP32 DISCONNECTED
```

 ## GPS unavailable

 Display:

```
GPS LOCATION UNAVAILABLE
```

 ## Internet unavailable

 Store the event locally and attempt synchronization when connectivity returns.

 ## Phone battery low

 Display a warning.

 ## False accident

 Allow the user to cancel the emergency alert.

---

 # 26\. Security and Privacy

 The application may handle location and emergency-contact information.

 Therefore:

 - Request only required permissions.
- Protect Firebase data with security rules.
- Do not expose accident records publicly.
- Do not store unnecessary personal information.
- Use authentication for cloud access.
- Protect emergency-contact information.
- Use secure communication wherever supported.

---

 # 27\. Important Prototype Limitations

 This project is a prototype and should not initially be presented as a guaranteed emergency-response system.

 Limitations include:

 - Sensor-based accident detection can produce false positives.
- Some accidents may not be detected.
- Smartphone GPS may be unavailable or inaccurate.
- Bluetooth may disconnect.
- Mobile Internet may be unavailable.
- The smartphone may run out of battery.
- Nearby-hospital information may not mean that a hospital has received the alert.
- Emergency services may require separate official integration.

---

 # 28\. Recommended Build Order

 Do not build everything simultaneously.

 Use this order:

```
1. ESP32
     ↓
2. ADXL345
     ↓
3. SW-420
     ↓
4. OLED
     ↓
5. Buzzer + LEDs
     ↓
6. Emergency Button
     ↓
7. Accident Detection
     ↓
8. Bluetooth
     ↓
9. Android App
     ↓
10. GPS
     ↓
11. Firebase
     ↓
12. Hospital Search
     ↓
13. Emergency Notifications
     ↓
14. Full Integration
     ↓
15. Testing
```

---

 # 29\. Minimum Viable Prototype (MVP)

 For the first working version, implement only:

```
ESP32
+
ADXL345
+
SW-420
+
Buzzer
+
LED
+
Emergency Button
+
Bluetooth
+
Android App
+
GPS
```

 The first successful demonstration should be:

```
Simulated Accident
      ↓
ESP32 Detects
      ↓
Buzzer + LED
      ↓
Android Receives Alert
      ↓
Android Gets GPS
      ↓
Location Displayed
```

 After this works, add Firebase, hospital search, and emergency notifications.

---

 # 30\. Final Demonstration

 A good project demonstration should show:

```
STEP 1
Power ON system
        ↓
STEP 2
ESP32 initializes
        ↓
STEP 3
Android connects
        ↓
STEP 4
Simulate accident
        ↓
STEP 5
ADXL345 + SW-420 detect event
        ↓
STEP 6
Buzzer + LED activate
        ↓
STEP 7
Android receives alert
        ↓
STEP 8
Phone obtains GPS
        ↓
STEP 9
Accident stored in Firebase
        ↓
STEP 10
Nearby hospitals displayed
        ↓
STEP 11
Accident location opened on map
        ↓
STEP 12
Emergency notification demonstrated
```

---

 # 31\. Project Deliverables

 At the end of the project, prepare:

 - [ ] Working ESP32 hardware
- [ ] Circuit diagram
- [ ] ESP32 source code
- [ ] Android application
- [ ] Firebase database
- [ ] Hospital-search feature
- [ ] Accident detection algorithm
- [ ] Test results
- [ ] Project report
- [ ] Presentation/PPT
- [ ] Demonstration video
- [ ] User manual
- [ ] Installation instructions

---

 # 32\. Final System

 The completed prototype will follow this workflow:

```
       ACCIDENT
           |
           v
    ADXL345 + SW-420
           |
           v
         ESP32
           |
     +-----+-----+
     |     |     |
     v     v     v
  Buzzer LED   OLED
           |
           v
       Bluetooth
           |
           v
      Android App
           |
      +----+----+
      |         |
      v         v
     GPS     Internet
      |         |
      +----+----+
           |
           v
        Firebase
           |
     +-----+------+
     |            |
     v            v
Hospitals    Emergency
             Contacts
```

 ## Project Goal

 Build a prototype that can:

 > **Detect a possible accident, obtain the smartphone's location, communicate the event to the Android application, store the accident information in the cloud, identify nearby hospitals, and provide emergency notification functionality.**