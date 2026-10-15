// Copyright 2020 Espressif Systems (Shanghai) PTE LTD
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


package com.espressif.provisioning.transport;

import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothProfile;
import android.content.Context;
import android.os.Build;
import android.util.Log;

import com.espressif.provisioning.DeviceConnectionEvent;
import com.espressif.provisioning.ESPConstants;
import com.espressif.provisioning.listeners.ResponseListener;

import org.greenrobot.eventbus.EventBus;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;

/**
 * Bluetooth implementation of the Transport protocol.
 */
public class BLETransport implements Transport {

    private static final String TAG = "Espressif::" + BLETransport.class.getSimpleName();

    private Context context;
    private BluetoothDevice currentDevice;
    private BluetoothGatt bluetoothGatt;
    private BluetoothGattService service;
    private ResponseListener currentResponseListener;
    private Semaphore transportToken;
    // Only data requests acquire this permit. The initial protocol-version
    // probe is a plain GATT read, so releasing the permit for that read would
    // inflate the semaphore and make the next Security1 request race with
    // the callback that announced the connection.
    private boolean transportTokenHeld = false;
    private ExecutorService dispatcherThreadPool;
    private HashMap<String, String> uuidMap = new HashMap<>();
    private ArrayList<String> charUuidList = new ArrayList<>();

    private String serviceUuid;
    public ArrayList<String> deviceCapabilities = new ArrayList<>();
    public String versionInfo;

    /**
     * Create BLETransport implementation
     *
     * @param context
     */
    public BLETransport(Context context) {
        this.context = context;
        this.transportToken = new Semaphore(1);
        this.dispatcherThreadPool = Executors.newSingleThreadExecutor();
    }

    /**
     * BLE implementation of Transport protocol
     *
     * @param path     path of the config endpoint.
     * @param data     config data to be sent
     * @param listener listener implementation which receives events when response is received.
     */
    @Override
    public void sendConfigData(String path, byte[] data, ResponseListener listener) {

        if (uuidMap.containsKey(path)) {

            BluetoothGattCharacteristic characteristic = service.getCharacteristic(UUID.fromString(uuidMap.get(path)));

            if (characteristic == null) {
                characteristic = service.getCharacteristic(UUID.fromString("0000ff52-0000-1000-8000-00805f9b34fb"));
            }

            if (characteristic != null) {
                try {
                    this.transportToken.acquire();
                    this.transportTokenHeld = true;
                    characteristic.setValue(data);
                    currentResponseListener = listener;
                    if (!bluetoothGatt.writeCharacteristic(characteristic)) {
                        currentResponseListener = null;
                        this.transportTokenHeld = false;
                        this.transportToken.release();
                        throw new IllegalStateException("BLE write was not started");
                    }
                } catch (Exception e) {
                    /* Bloom: no credential logs. */
                    if (this.transportTokenHeld) {
                        this.transportTokenHeld = false;
                        this.transportToken.release();
                    }
                    listener.onFailure(e);
                }
            } else {
                /* Bloom: SDK logging disabled. */;
                currentResponseListener = listener;
                if (currentResponseListener != null) {
                    currentResponseListener.onFailure(new RuntimeException("Characteristic is not available for given path."));
                }
            }
        } else {
            currentResponseListener = listener;
            /* Bloom: SDK logging disabled. */;
            if (currentResponseListener != null) {
                currentResponseListener.onFailure(new RuntimeException("Characteristic is not available for given path."));
            }
        }
    }

    /**
     * Connect to a BLE peripheral device.
     *
     * @param bluetoothDevice    The peripheral device
     * @param primaryServiceUuid Primary Service UUID
     */
    public void connect(BluetoothDevice bluetoothDevice, UUID primaryServiceUuid) {
        uuidMap.clear();
        charUuidList.clear();
        deviceCapabilities.clear();
        currentResponseListener = null;
        if (transportTokenHeld) {
            transportTokenHeld = false;
            transportToken.release();
        }
        this.currentDevice = bluetoothDevice;
        this.serviceUuid = primaryServiceUuid.toString();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            bluetoothGatt = this.currentDevice.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE);
        } else {
            bluetoothGatt = this.currentDevice.connectGatt(context, false, gattCallback);
        }
    }

    /**
     * Disconnect from the current connected peripheral
     */
    public void disconnect() {

        /* Bloom: SDK logging disabled. */;

        if (this.bluetoothGatt != null) {
            this.bluetoothGatt.disconnect();
            this.bluetoothGatt.close();
            bluetoothGatt = null;
        }
    }

    public void refreshServices() {
        /* Bloom: SDK logging disabled. */;
        try {
            // BluetoothGatt gatt
            final Method refresh = bluetoothGatt.getClass().getMethod("refresh");
            if (refresh != null) {
                refresh.invoke(bluetoothGatt);
            }
        } catch (Exception e) {
            /* Bloom: no credential logs. */
        }
        bluetoothGatt.discoverServices();
    }

    private BluetoothGattCallback gattCallback = new BluetoothGattCallback() {

        @Override
        public void onConnectionStateChange(BluetoothGatt gatt, int status, int newState) {

            super.onConnectionStateChange(gatt, status, newState);
            if (gatt != bluetoothGatt) return;
            /* Bloom: SDK logging disabled. */;

            if (status == BluetoothGatt.GATT_FAILURE) {
                EventBus.getDefault().post(new DeviceConnectionEvent(ESPConstants.EVENT_DEVICE_CONNECTION_FAILED, BLETransport.this));
                return;
            } else if (status == 133) {
                EventBus.getDefault().post(new DeviceConnectionEvent(ESPConstants.EVENT_DEVICE_CONNECTION_FAILED, BLETransport.this));
                return;
            } else if (status != BluetoothGatt.GATT_SUCCESS && newState != BluetoothProfile.STATE_DISCONNECTED) {
                // TODO need to check this status
                return;
            }

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                /* Bloom: SDK logging disabled. */;
                gatt.requestMtu(512);
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                /* Bloom: SDK logging disabled. */;
                EventBus.getDefault().post(new DeviceConnectionEvent(ESPConstants.EVENT_DEVICE_DISCONNECTED, BLETransport.this));
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt gatt, int status) {

            super.onServicesDiscovered(gatt, status);
            if (gatt != bluetoothGatt) return;
            /* Bloom: SDK logging disabled. */;

            if (status != BluetoothGatt.GATT_SUCCESS) {
                /* Bloom: SDK logging disabled. */;
                EventBus.getDefault().post(new DeviceConnectionEvent(ESPConstants.EVENT_DEVICE_CONNECTION_FAILED, BLETransport.this));
                return;
            }

            service = gatt.getService(UUID.fromString(serviceUuid));

            if (service == null) {
                /* Bloom: SDK logging disabled. */;
                EventBus.getDefault().post(new DeviceConnectionEvent(ESPConstants.EVENT_DEVICE_CONNECTION_FAILED, BLETransport.this));
                return;
            }

            for (BluetoothGattCharacteristic characteristic : service.getCharacteristics()) {

                if (characteristic == null) {
                    /* Bloom: SDK logging disabled. */;
                    EventBus.getDefault().post(new DeviceConnectionEvent(ESPConstants.EVENT_DEVICE_CONNECTION_FAILED, BLETransport.this));
                    return;
                }

                String uuid = characteristic.getUuid().toString();
                /* Bloom: SDK logging disabled. */;
                charUuidList.add(uuid);

                characteristic.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
            }

            readNextDescriptor();
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt gatt, BluetoothGattDescriptor descriptor, int status) {

            if (gatt != bluetoothGatt) return;
            if (status == BluetoothGatt.GATT_SUCCESS) {
                /* Bloom: SDK logging disabled. */;
            } else {
                /* Bloom: SDK logging disabled. */;
                EventBus.getDefault().post(new DeviceConnectionEvent(ESPConstants.EVENT_DEVICE_CONNECTION_FAILED, BLETransport.this));
            }
        }

        @Override
        public void onDescriptorRead(BluetoothGatt gatt, BluetoothGattDescriptor descriptor, int status) {
            if (gatt != bluetoothGatt) return;
            byte[] data = descriptor.getValue();
            if (status != BluetoothGatt.GATT_SUCCESS || data == null || data.length == 0) {
                failConnection();
                return;
            }
            String charUuid = descriptor.getCharacteristic().getUuid().toString();
            uuidMap.put(new String(data, StandardCharsets.UTF_8), charUuid);
            readNextDescriptor();
        }

        @Override
        public void onMtuChanged(BluetoothGatt gatt, int mtu, int status) {
            super.onMtuChanged(gatt, mtu, status);
            if (gatt != bluetoothGatt) return;
            if (status == BluetoothGatt.GATT_SUCCESS) {
                /* Bloom: SDK logging disabled. */;
            }
            gatt.discoverServices();
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic) {
            if (gatt != bluetoothGatt) return;
            /* Bloom: SDK logging disabled. */;
            super.onCharacteristicChanged(gatt, characteristic);
        }

        @Override
        public void onCharacteristicRead(BluetoothGatt gatt,
                                         final BluetoothGattCharacteristic characteristic,
                                         int status) {

            if (gatt != bluetoothGatt) return;

            /* Bloom: SDK logging disabled. */;
            super.onCharacteristicRead(gatt, characteristic, status);

            final String protoUuid = uuidMap.get(ESPConstants.HANDLER_PROTO_VER);
            final boolean isProtoVersion = protoUuid != null
                    && protoUuid.equals(characteristic.getUuid().toString());

            if (status != BluetoothGatt.GATT_SUCCESS || characteristic.getValue() == null) {
                final ResponseListener responseListener = currentResponseListener;
                currentResponseListener = null;
                if (responseListener != null) {
                    responseListener.onFailure(new Exception("Read from BLE failed"));
                }
                if (transportTokenHeld) {
                    transportTokenHeld = false;
                    transportToken.release();
                }
                failConnection();
                return;
            }

            if (isProtoVersion) {

                String data = new String(characteristic.getValue(), StandardCharsets.UTF_8);
                /* Bloom: SDK logging disabled. */;
                versionInfo = data;

                try {
                    JSONObject jsonObject = new JSONObject(data);
                    JSONObject provInfo = jsonObject.getJSONObject("prov");

                    String deviceVersion = provInfo.getString("ver");
                    /* Bloom: SDK logging disabled. */;

                    JSONArray capabilities = provInfo.getJSONArray("cap");

                    for (int i = 0; i < capabilities.length(); i++) {
                        String cap = capabilities.getString(i);
                        deviceCapabilities.add(cap);
                    }
                    /* Bloom: SDK logging disabled. */;

                } catch (JSONException e) {
                    /* Bloom: no credential logs. */
                    /* Bloom: SDK logging disabled. */;
                }

                // The event subscriber starts Security1 immediately. Release
                // the previous data operation before publishing the event so
                // Android cannot block its GATT callback thread on the same
                // semaphore.
            }

            final ResponseListener responseListener = currentResponseListener;
            currentResponseListener = null;
            final boolean hadResponse = responseListener != null;
            if (hadResponse && status != BluetoothGatt.GATT_SUCCESS) {
                responseListener.onFailure(new Exception("Read from BLE failed"));
            }
            if (transportTokenHeld) {
                transportTokenHeld = false;
                transportToken.release();
            }

            if (isProtoVersion) {
                EventBus.getDefault().post(new DeviceConnectionEvent(ESPConstants.EVENT_DEVICE_CONNECTED, BLETransport.this));
            }

            if (hadResponse && status == BluetoothGatt.GATT_SUCCESS) {

                if (status == BluetoothGatt.GATT_SUCCESS) {
                    /*
                     * Need to dispatch this on another thread since the caller
                     * might decide to enqueue another send operation on success
                     * of the first.
                     */
                    dispatcherThreadPool.submit(new Runnable() {
                        @Override
                        public void run() {
                            byte[] charValue = characteristic.getValue();
                            responseListener.onSuccess(charValue);
                        }
                    });
                }
            }
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, int status) {

            if (gatt != bluetoothGatt) return;
            /* Bloom: SDK logging disabled. */;
            /* Bloom: SDK logging disabled. */;
            super.onCharacteristicWrite(gatt, characteristic, status);

            if (status == BluetoothGatt.GATT_SUCCESS) {
                bluetoothGatt.readCharacteristic(characteristic);
            } else {
                if (currentResponseListener != null) {
                    currentResponseListener.onFailure(new Exception("Write to BLE failed"));
//                    EventBus.getDefault().post(new DeviceProvEvent(LibConstants.EVENT_DEVICE_COMMUNICATION_FAILED));
                }
                if (transportTokenHeld) {
                    transportTokenHeld = false;
                    transportToken.release();
                }
            }
        }
    };

    private void readNextDescriptor() {
        for (int i = 0; i < charUuidList.size(); i++) {

            String uuid = charUuidList.get(i);

            if (!uuidMap.containsValue(uuid)) {

                // Read descriptor
                BluetoothGattCharacteristic characteristic = service.getCharacteristic(UUID.fromString(uuid));
                if (characteristic == null) {
                    failConnection();
                    return;
                }

                for (BluetoothGattDescriptor descriptor : characteristic.getDescriptors()) {
                    String desUuid = descriptor.getUuid().toString();
                    if (desUuid.contains(ESPConstants.USER_DESCRIPTION_UUID)) {
                        // Reading 0x2901 supplies the endpoint name. Removing
                        // SDK logs must never remove this GATT operation.
                        if (!bluetoothGatt.readDescriptor(descriptor)) failConnection();
                        return; // One operation at a time; continue in callback.
                    }
                }
                // Characteristics without a user description are not endpoints.
            }
        }
        String protoUuid = uuidMap.get(ESPConstants.HANDLER_PROTO_VER);
        BluetoothGattCharacteristic characteristic = protoUuid == null ? null
                : service.getCharacteristic(UUID.fromString(protoUuid));
        if (characteristic == null) {
            failConnection();
            return;
        }
        characteristic.setValue("ESP");
        if (!bluetoothGatt.writeCharacteristic(characteristic)) failConnection();
    }

    private void failConnection() {
        disconnect();
        EventBus.getDefault().post(new DeviceConnectionEvent(ESPConstants.EVENT_DEVICE_CONNECTION_FAILED, BLETransport.this));
    }
}
