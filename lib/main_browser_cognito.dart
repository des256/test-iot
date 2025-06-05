import 'dart:convert';
import 'dart:typed_data';
import 'package:typed_data/typed_buffers.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';
import 'package:mqtt5_client/mqtt5_browser_client.dart';

import 'secrets.dart';

enum _State {
  initializing,
  connected,
  error,
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  _State _state = _State.initializing;
  String? _errorMessage;
  late CognitoUserPool _cognitoUserPool;
  late CognitoUserSession _cognitoSession;
  late String _awsAccessKeyId;
  late String _awsSecretKey;
  late String _awsSessionToken;
  late MqttClient? _mqtt;

  Future<bool> _getAwsCredentialsFromCognito() async {
    _cognitoUserPool =
        CognitoUserPool(secretCognitoPoolId, secretCognitoAppClientId);
    CognitoCredentials cognitoCredentials =
        CognitoCredentials(secretCognitoIdentityPoolId, _cognitoUserPool);
    final user = CognitoUser(secretCognitoUserName, _cognitoUserPool);
    final authDetails = AuthenticationDetails(
        username: secretCognitoUserName, password: secretCognitoPassword);
    user.setAuthenticationFlowType("USER_PASSWORD_AUTH");
    try {
      _cognitoSession = (await user.authenticateUser(authDetails))!;
      await cognitoCredentials
          .getAwsCredentials(_cognitoSession.getIdToken().getJwtToken());
      _awsAccessKeyId = cognitoCredentials.accessKeyId!;
      _awsSecretKey = cognitoCredentials.secretAccessKey!;
      _awsSessionToken = cognitoCredentials.sessionToken!;
      return true;
    } catch (error) {
      setState(() {
        _errorMessage = "Cognito error: $error";
        _state = _State.error;
      });
      return false;
    }
  }

  Future<String> _buildAwsRequestUrlFromAwsCredentials() async {
    final awsCredentials = AWSCredentials(_awsAccessKeyId, _awsSecretKey);
    final signer = AWSSigV4Signer(
        credentialsProvider: AWSCredentialsProvider(awsCredentials));
    final credentialScope = AWSCredentialScope.raw(
        region: secretAwsRegion, service: 'iotdevicegateway');
    final baseUrl = 'wss://$secretIotCoreEndpoint/mqtt';
    final request = AWSHttpRequest.get(Uri.parse(baseUrl));
    final signedUrl = await signer.presign(request,
        credentialScope: credentialScope, expiresIn: Duration(seconds: 300));
    final encodedSessionToken = Uri.encodeComponent(_awsSessionToken);
    final signedUrlWithSessionToken =
        '${signedUrl.toString()}&X-Amz-Security-Token=$encodedSessionToken';
    return signedUrlWithSessionToken;
  }

  Future<MqttClient?> _connectToMqtt(String signedUrl) async {
    final clientId = 'basicPubSub'; // from Python/JS examples
    //final clientId = secretCognitoAppClientId;
    if (kIsWeb) {
      // when run fron inside flutter web app in browser
      final mqtt = MqttBrowserClient(signedUrl, clientId);
      mqtt.logging(on: true);
      mqtt.port = 443;
      mqtt.websocketProtocols = ['mqtt'];
      mqtt.connectionMessage = MqttConnectMessage()
          .startClean()
          .withWillQos(MqttQos.atLeastOnce)
          .keepAliveFor(40);
      mqtt.onConnected = () {
        debugPrint('MQTT connected');
      };
      mqtt.onDisconnected = () {
        debugPrint('MQTT disconnected');
      };
      mqtt.onSubscribed = (topic) {
        debugPrint('MQTT subscribed to $topic');
      };
      mqtt.onUnsubscribed = (topic) {
        debugPrint('MQTT unsubscribed from $topic');
      };
      mqtt.onSubscribeFail = (subscription) {
        debugPrint('MQTT subscribe failed');
      };
      try {
        await mqtt.connect();
        setState(() {
          _state = _State.connected;
        });
        return mqtt;
      } catch (error) {
        setState(() {
          _state = _State.error;
          _errorMessage = 'Cannot connect to MQTT: $error';
        });
        return null;
      }
    } else {
      // when run from projector Android app
      final mqtt = MqttServerClient(signedUrl, clientId);
      mqtt.port = 8883;
      // TODO: further initialization
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    () async {
      if (!await _getAwsCredentialsFromCognito()) {
        return;
      }

      final signedUrl = await _buildAwsRequestUrlFromAwsCredentials();

      _mqtt = await _connectToMqtt(signedUrl);
    }();
  }

  void _publishSpamMessage() {
    final topic = 'testTopic';
    final buffer = Uint8Buffer();
    buffer.addAll(utf8.encode('Hello, IoT!'));
    try {
      _mqtt!.publishMessage(topic, MqttQos.atLeastOnce, buffer);
    } catch (error) {
      setState(() {
        _state = _State.error;
        _errorMessage = 'Cannot publish message: $error';
      });
    }
  }

  Widget _buildHomePage() {
    switch (_state) {
      case _State.initializing:
        return const Center(child: CircularProgressIndicator());
      case _State.connected:
        return Center(
          child: Column(
            children: [
              Text('Connected'),
              SizedBox(height: 40),
              ElevatedButton(
                  onPressed: _publishSpamMessage,
                  child: const Text('Spam IoT')),
            ],
          ),
        );
      case _State.error:
        return Center(child: Text(_errorMessage!));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter AWS IoT Browser Cognito',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Flutter AWS IoT Browser Cognito'),
        ),
        body: _buildHomePage(),
      ),
    );
  }
}

void main() {
  print('STARTING APP (print)');
  runApp(const MyApp());
}
