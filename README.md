# Flutter AWS IoT Demo

A Flutter application demonstrating AWS IoT Core integration with device shadows and MQTT communication.

## Features

- AWS IoT Core integration using MQTT over WebSocket
- Device shadow synchronization
- Real-time state updates
- Cognito authentication
- Layer state management

## Setup

1. Create `lib/secrets.dart` file with your AWS credentials:

```dart
final String awsRegion = 'eu-west-1';
final String secretIotCoreMqttEndpoint = 'your-mqtt-endpoint.iot.region.amazonaws.com';
final String secretIotCoreHttpEndpoint = 'your-http-endpoint.iot.region.amazonaws.com';
final String secretStationCode = 'YOUR_STATION_CODE';
final String thingType = 'your-thing-type';
```

2. Add required dependencies to `pubspec.yaml`:

```yaml
dependencies:
  aws_signature_v4: ^0.6.4
  mqtt5_client: ^4.0.0
  amazon_cognito_identity_dart_2: ^3.0.0
  connectivity_plus: ^5.0.0
```

## Usage

### Initialize IoT Service

```dart
final iotService = IotService(
  region: awsRegion,
  mqttEndpoint: secretIotCoreMqttEndpoint,
  httpEndpoint: secretIotCoreHttpEndpoint,
  stationCode: secretStationCode,
);

// Set AWS credentials
iotService.setCredentials(AwsCredentials(
  accessKeyId: 'YOUR_ACCESS_KEY',
  secretKey: 'YOUR_SECRET_KEY',
  sessionToken: 'YOUR_SESSION_TOKEN',
));
```

### Connect and Initialize Thing

```dart
// Create or get existing thing
await iotService.createOrGetThing();

// Connect MQTT client
final mqttClient = await iotService.connectMqtt();

// Get initial state
await iotService.getInitialState();
```

### Update Device State

```dart
// Update internal state
iotService.updateStateInternal({
  'layer': newLayerValue
});

// State will be automatically synchronized with the device shadow
```

### Handle State Updates

```dart
mqttClient.updates.listen((List<MqttReceivedMessage<MqttMessage>> c) {
  for (final message in c) {
    final payload = message.payload as MqttPublishMessage;
    final topic = message.topic;
    final body = utf8.decode(payload.payload.message!.toList());
    
    if (topic == '${iotService.prefix}/update/delta') {
      final jsonBody = jsonDecode(body);
      iotService.updateStateFromDelta(jsonBody);
      // UI will be updated automatically
    }
  }
});
```

## Device Shadow Structure

The device shadow maintains the following state structure:

```json
{
  "state": {
    "desired": {
      "layer": 1
    },
    "reported": {
      "layer": 1
    }
  }
}
```

## Topics

The application subscribes to the following shadow topics:

- `$aws/things/{thingId}/shadow/get`
- `$aws/things/{thingId}/shadow/update`
- `$aws/things/{thingId}/shadow/delete`
- `$aws/things/{thingId}/shadow/get/accepted`
- `$aws/things/{thingId}/shadow/get/rejected`
- `$aws/things/{thingId}/shadow/update/delta`
- `$aws/things/{thingId}/shadow/update/accepted`
- `$aws/things/{thingId}/shadow/update/rejected`
- `$aws/things/{thingId}/shadow/update/documents`
- `$aws/things/{thingId}/shadow/delete/accepted`
- `$aws/things/{thingId}/shadow/delete/rejected`

## Error Handling

The application includes comprehensive error handling for:
- Network connectivity issues
- MQTT connection failures
- AWS IoT API errors
- State synchronization conflicts

## Security

- Uses AWS Signature V4 for request signing
- Supports AWS Cognito authentication
- Implements secure WebSocket connections
- Handles session tokens properly

## Thing Naming Convention

Things are automatically named using the pattern: `vullow_station_{stationCode}`

For example, with `stationCode = "QWERTY123222"`, the thing name would be `vullow_station_QWERTY123222`