import 'dart:convert';
import 'package:test_iot/secrets.dart';
import 'package:typed_data/typed_buffers.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:aws_common/aws_common.dart';
import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';
import 'package:collection/collection.dart';

class AwsCredentials {
  final String accessKeyId;
  final String secretKey;
  final String sessionToken;

  AwsCredentials({
    required this.accessKeyId,
    required this.secretKey,
    required this.sessionToken,
  });
}

class IotService {
  final String region;
  final String mqttEndpoint;
  final String httpEndpoint;
  final String stationCode;
  final String thingId;
  late String prefix;
  late AWSSigV4Signer _signer;
  AwsCredentials? _credentials;
  MqttClient? _mqttClient;
  Map<String, dynamic> state = {};

  IotService({
    required this.region,
    required this.mqttEndpoint,
    required this.httpEndpoint,
    required this.stationCode,
  }) : thingId = "vullow_station_$stationCode"
     {
    prefix = "\$aws/things/$thingId/shadow";
  }

    void setCredentials(AwsCredentials credentials) {
      _credentials = credentials;
    }

    Future<void> getInitialState() async {
    final client = AWSHttpClient();
      final shadowRequest = AWSHttpRequest.get(
        Uri.parse('https://$httpEndpoint/things/$thingId/shadow'),
      );
      final credentialScope = AWSCredentialScope(
        region: region,
        service: AWSService('iotdevicegateway'),
      );

      final signedRequest =
      await _signer.sign(shadowRequest, credentialScope: credentialScope);
      final response = await (await client.send(signedRequest)).response;

      if (response.statusCode != 200 && response.statusCode != 404) {
        final errorBody = await response.decodeBody();
        throw Exception('Failed to create thing shadow: $errorBody');
      } else if (response.statusCode == 404) {
        final initialState = {
          "layer": 1
        };
        publishMessage('\$aws/things/$thingId/shadow/update', {
          "state": {
            "desired": initialState,
            "reported": initialState,
          }
        });
        this.state = initialState;
        return;
      }
      final jsonBody = json.decode(await response.decodeBody());
      this.state = jsonBody['state']['desired'];
      if (!DeepCollectionEquality().equals(
          jsonBody['state']['desired'], jsonBody['state']['reported'])) {
        updateStateInternal(state);
      }
    }

    Future<void> createOrGetThing() async {
      if (_credentials == null) {
        throw Exception('AWS credentials not set');
      }

      try {
        final credentialScope = AWSCredentialScope(
          region: region,
          service: AWSService('iot'),
        );

        _signer = AWSSigV4Signer(
          credentialsProvider: AWSCredentialsProvider(
            AWSCredentials(
              _credentials!.accessKeyId,
              _credentials!.secretKey,
              _credentials!.sessionToken,
            ),
          ),
        );

        final client = AWSHttpClient();

        final createThingRequest = AWSHttpRequest.post(
          Uri.parse('https://iot.$region.amazonaws.com/things/$thingId'),
          headers: {'Content-Type': 'application/json'},
          body: utf8.encode(json.encode({
            'thingTypeName': thingType,
            'attributePayload': {
              'attributes': {
                'stationCode': stationCode,
              },
              'merge': true,
            }
          })),
        );

        final signedRequest = await _signer.sign(createThingRequest,
            credentialScope: credentialScope);
        final response = await (await client.send(signedRequest)).response;

        if (response.statusCode != 200 && response.statusCode != 409) {
          // 409 means thing already exists, which is fine
          final errorBody = await response.decodeBody();
          throw Exception('Failed to create IoT thing: $errorBody');
        }

        print('IoT thing $thingId is ready');
      } catch (error) {
        print('Error creating IoT thing: $error');
        rethrow;
      }
    }

    Future<String> buildWebSocketUrl() async {
      if (_credentials == null) {
        throw Exception('AWS credentials not set');
      }

      final awsCredentials = AWSCredentials(
        _credentials!.accessKeyId,
        _credentials!.secretKey,
      );

      final signer = AWSSigV4Signer(
          credentialsProvider: AWSCredentialsProvider(awsCredentials));
      final credentialScope =
      AWSCredentialScope.raw(region: region, service: 'iotdevicegateway');
      final baseUrl = 'wss://$mqttEndpoint/mqtt';
      final request = AWSHttpRequest.get(Uri.parse(baseUrl));
      final signedUrl = await signer.presign(request,
          credentialScope: credentialScope, expiresIn: Duration(seconds: 300));
      final encodedSessionToken = Uri.encodeComponent(
          _credentials!.sessionToken);
      return '${signedUrl
          .toString()}&X-Amz-Security-Token=$encodedSessionToken';
    }

    Future<MqttClient> connectMqtt() async {
      final signedUrl = await buildWebSocketUrl();
      final clientId = 'vullow_station-$stationCode';
      final mqtt = MqttServerClient(signedUrl, clientId);
      mqtt.port = 443;
      mqtt.useWebSocket = true;
      mqtt.autoReconnect = true;

      mqtt.onDisconnected = () {
        print('MQTT Disconnected');
      };
      mqtt.onConnected = () {
        print('MQTT Connected');
      };

      mqtt.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .startClean()
          .withWillQos(MqttQos.atLeastOnce);

      try {
        await mqtt.connect();
        _mqttClient = mqtt;

        final List<String> topics = [
          '$prefix/get',
          '$prefix/update',
          '$prefix/delete',
          '$prefix/get/accepted',
          '$prefix/get/rejected',
          '$prefix/update/delta',
          '$prefix/update/accepted',
          '$prefix/update/rejected',
          '$prefix/update/documents',
          '$prefix/delete/accepted',
          '$prefix/delete/rejected',
        ];

        for (final topic in topics) {
          mqtt.subscribe(topic, MqttQos.atLeastOnce);
          print('Subscribed to topic: $topic');
        }
        return mqtt;
      } catch (e) {
        print('MQTT Connection error: $e');
        rethrow;
      }
    }

    void publishMessage(String topic, Object message) {
      if (_mqttClient == null) {
        throw Exception('MQTT client not connected');
      }

      final buffer = Uint8Buffer();
      buffer.addAll(utf8.encode(json.encode(message)));

      try {
        _mqttClient!.publishMessage(topic, MqttQos.atLeastOnce, buffer);
        print('Published to topic: $topic');
      } catch (error) {
        print('Error publishing message: $error');
        rethrow;
      }
    }

    void disconnect() {
      _mqttClient?.disconnect();
      _mqttClient = null;
    }

    void updateStateInternal(state) {
      this.state = {...this.state, ...state};
      publishMessage('$prefix/update', {
        "state": {
          "desired": this.state,
        }
      });
    }

    void updateStateFromDelta(stateDelta) {
      this.state = {...this.state, ...stateDelta['state']};
      publishMessage('$prefix/update', {
        "state": {
          "desired": this.state,
          "reported": this.state,
        }
      });
    }
  }
