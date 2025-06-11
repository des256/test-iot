import 'dart:convert';
import 'package:typed_data/typed_buffers.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'secrets.dart';
import 'iot_service.dart';

enum _State {
  initializing,
  connected,
  error,
  noInternet,
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  _State _state = _State.initializing;
  _State? _previousState;
  String? _errorMessage;
  late CognitoUserPool _cognitoUserPool;
  late CognitoUserSession? _cognitoSession;
  late String _awsAccessKeyId;
  late String _awsSecretKey;
  late String _awsSessionToken;
  late IotService _iotService;
  late MqttClient? _mqtt;
  final TextEditingController _messageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _iotService = IotService(
      region: secretAwsRegion,
      mqttEndpoint: secretIotCoreMqttEndpoint,
      httpEndpoint: secretIotCoreHttpEndpoint,
      stationCode: secretStationCode,
    );
    _initConnectivity();
    _initializeApp();
  }

  Future<bool> _getAwsCredentialsFromCognito() async {
    _cognitoUserPool =
        CognitoUserPool(secretCognitoPoolId, secretCognitoAppClientId);
    CognitoCredentials cognitoCredentials =
        CognitoCredentials(secretCognitoIdentityPoolId, _cognitoUserPool);

    try {
      await cognitoCredentials.getGuestAwsCredentialsId();
      _awsAccessKeyId = cognitoCredentials.accessKeyId!;
      _awsSecretKey = cognitoCredentials.secretAccessKey!;
      _awsSessionToken = cognitoCredentials.sessionToken!;

      _iotService.setCredentials(AwsCredentials(
        accessKeyId: _awsAccessKeyId,
        secretKey: _awsSecretKey,
        sessionToken: _awsSessionToken,
      ));

      return true;
    } catch (error) {
      setState(() {
        _errorMessage = "Cognito error: $error";
        _state = _State.error;
      });
      return false;
    }
  }

  Future<void> _initializeApp() async {
    if (!await _getAwsCredentialsFromCognito()) {
      return;
    }

    try {
      await _iotService.createOrGetThing();
      _mqtt = await _iotService.connectMqtt();
      await _iotService.getInitialState();

      _mqtt!.updates.listen((List<MqttReceivedMessage<MqttMessage>> c) {
        for (final MqttReceivedMessage<MqttMessage> message in c) {
          final payload = message.payload as MqttPublishMessage;
          final String? topic = message.topic;
          final payloadBytes = payload.payload.message;
          final body = utf8.decode(payloadBytes!.toList());
          final jsonBody = jsonDecode(body);
          print('Message received ($topic): $body');
          if ('${_iotService.prefix}/update/delta' == topic) {
            _iotService.updateStateFromDelta(jsonBody);
            setState(() {});
          }
        }
      });

      setState(() {
        _state = _State.connected;
      });
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
        _state = _State.error;
      });
    }
  }

  Future<void> _initConnectivity() async {
    final connectivity = Connectivity();
    connectivity.onConnectivityChanged.listen((ConnectivityResult result) {
      if (result == ConnectivityResult.none) {
        if (_state != _State.noInternet) {
          _previousState = _state;
          setState(() {
            _state = _State.noInternet;
            _mqtt?.disconnect();
            _mqtt = null;
          });
        }
      } else {
        if (_state == _State.noInternet && _previousState != null) {
          setState(() {
            _state = _previousState!;
          });
          if (_previousState == _State.connected && _mqtt == null) {
            _initializeApp();
          }
        }
      }
    });

    final result = await connectivity.checkConnectivity();
    if (result == ConnectivityResult.none) {
      setState(() {
        _previousState = _state;
        _state = _State.noInternet;
      });
    }
  }

  void _publishSpamMessage() {
    final message = _messageController.text.isNotEmpty 
        ? int.parse(_messageController.text)
        : 0;
    try {
      _iotService.updateStateInternal({'layer': message});
      _messageController.clear();
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
        _state = _State.error;
      });
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _iotService.disconnect();
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Current layer: '),
                  Text(
                    _iotService?.state['layer']?.toString() ?? '-',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: TextField(
                  controller: _messageController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: InputDecoration(
                    hintText: 'Enter layer number',
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
      case _State.noInternet:
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.signal_wifi_off, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text('No Internet Connection',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text('Please check your connection and try again'),
            ],
          ),
        );
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
