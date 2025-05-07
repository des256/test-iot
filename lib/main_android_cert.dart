import 'dart:convert';

import 'package:typed_data/typed_buffers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  late MqttClient? _mqtt;

  Future<MqttClient?> _connectToMqtt(String url) async {
    print('Connecting to $url');
    final clientId = 'basicPubSub'; // from Python/JS examples
    //final clientId = secretCognitoAppClientId;
    final mqtt = MqttServerClient(url, clientId);
    mqtt.port = 8883;
    mqtt.secure = true;
    mqtt.logging(on: true);
    mqtt.securityContext.useCertificateChainBytes(await rootBundle
        .loadString('assets/vullow_station_test.cert.pem')
        .then((value) => value.codeUnits));
    mqtt.securityContext.usePrivateKeyBytes(await rootBundle
        .loadString('assets/vullow_station_test.private.key')
        .then((value) => value.codeUnits));
    mqtt.securityContext.setClientAuthoritiesBytes(await rootBundle
        .loadString('assets/root-CA.crt')
        .then((value) => value.codeUnits));
    mqtt.keepAlivePeriod = 20;
    mqtt.onBadCertificate = (object) {
      print('Bad certificate: $object');
      return true;
    };
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
  }

  @override
  void initState() {
    super.initState();
    () async {
      _mqtt = await _connectToMqtt('wss://$secretIotCoreEndpoint/mqtt');
    }();
  }

  void _publishSpamMessage() {
    final topic = 'testTopic';
    final buffer = Uint8Buffer();
    buffer.addAll(utf8.encode('Hello, IoT!'));
    try {
      _mqtt!.publishMessage(topic, MqttQos.atLeastOnce, buffer);
    } catch (error) {
      print('Cannot publish message: $error');
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
      title: 'Flutter AWS IoT Android Certificates',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Flutter AWS IoT Android Certificates'),
        ),
        body: _buildHomePage(),
      ),
    );
  }
}
