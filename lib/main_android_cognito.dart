import 'dart:convert';
import 'package:typed_data/typed_buffers.dart';

import 'package:flutter/material.dart';
import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';

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
  final TextEditingController _messageController = TextEditingController();

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
    final mqtt = MqttServerClient(signedUrl, clientId);
    mqtt.port = 443;
    mqtt.useWebSocket = true;

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
      setState(() {
        _state = _State.connected;
      });
      return mqtt;
    } catch (e) {
      print('MQTT Connection error: $e');
      setState(() {
        _state = _State.error;
        _errorMessage = 'Cannot connect to MQTT: $e';
      });
      return null;
    }

    return mqtt;
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
    final topic = 'android/test';
    final message = _messageController.text.isNotEmpty 
        ? _messageController.text 
        : 'Hello, IoT';
    final buffer = Uint8Buffer();
    buffer.addAll(utf8.encode(json.encode({"message": message})));
    try {
      _mqtt!.publishMessage(topic, MqttQos.atLeastOnce, buffer);
      _messageController.clear(); // Clear the input field after successful publish
    } catch (error) {
      setState(() {
        _state = _State.error;
        _errorMessage = 'Cannot publish message: $error';
      });
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Widget _buildHomePage() {
    switch (_state) {
      case _State.initializing:
        return const Center(child: CircularProgressIndicator());
      case _State.connected:
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Connected'),
              SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: TextField(
                  controller: _messageController,
                  decoration: InputDecoration(
                    hintText: 'Enter message to send',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              SizedBox(height: 20),
              ElevatedButton(
                  onPressed: _publishSpamMessage,
                  child: const Text('Send IoT Message')),
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
      title: 'Flutter AWS IoT Android Cognito',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Flutter AWS IoT Android Cognito'),
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
