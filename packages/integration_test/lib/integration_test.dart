// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart' as vm_io;

import '_callback_io.dart' if (dart.library.html) '_callback_web.dart' as driver_actions;
import '_extension_io.dart' if (dart.library.html) '_extension_web.dart';
import 'common.dart';
import 'src/channel.dart';

const String _success = 'success';

/// Whether results should be reported to the native side over the method
/// channel.
///
/// This is enabled by default for use by native test frameworks like Android
/// instrumentation or XCTest. When running with the Flutter Tool through
/// `flutter test integration_test` though, it will be disabled as the Flutter
/// tool will be responsible for collection of test results.
const bool _shouldReportResultsToNative = bool.fromEnvironment(
  'INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE',
  defaultValue: true,
);

/// A subclass of [LiveTestWidgetsFlutterBinding] that reports tests results
/// on a channel to adapt them to native instrumentation test format.
class IntegrationTestWidgetsFlutterBinding extends LiveTestWidgetsFlutterBinding implements IntegrationTestResults {
  /// Sets up a listener to report that the tests are finished when everything is
  /// torn down.
  IntegrationTestWidgetsFlutterBinding() {
    tearDownAll(() async {
      if (!_allTestsPassed.isCompleted) {
        _allTestsPassed.complete(failureMethodsDetails.isEmpty);
      }
      callbackManager.cleanup();

      // TODO(jiahaog): Print the message directing users to run with
      // `flutter test` when Web is supported.
      if (!_shouldReportResultsToNative || kIsWeb) {
        return;
      }

      try {
        await integrationTestChannel.invokeMethod<void>(
          'allTestsFinished',
          <String, dynamic>{
            'results': results.map<String, dynamic>((String name, Object result) {
              if (result is Failure) {
                return MapEntry<String, dynamic>(name, result.details);
              }
              return MapEntry<String, Object>(name, result);
            })
          },
        );
      } on MissingPluginException {
        print(r'''
Warning: integration_test plugin was not detected.

If you're running the tests with `flutter drive`, please make sure your tests
are in the `integration_test/` directory of your package and use
`flutter test $path_to_test` to run it instead.

If you're running the tests with Android instrumentation or XCTest, this means
that you are not capturing test results properly! See the following link for
how to set up the integration_test plugin:

https://flutter.dev/docs/testing/integration-tests#testing-on-firebase-test-lab
''');
      }
    });

    final TestExceptionReporter oldTestExceptionReporter = reportTestException;
    reportTestException =
        (FlutterErrorDetails details, String testDescription) {
      results[testDescription] = Failure(testDescription, details.toString());
      oldTestExceptionReporter(details, testDescription);
    };
  }

  @override
  bool get overrideHttpClient => false;

  @override
  bool get registerTestTextInput => false;

  Size? _surfaceSize;

  // This flag is used to print warning messages when tracking performance
  // under debug mode.
  static bool _firstRun = false;

  /// Artificially changes the surface size to `size` on the Widget binding,
  /// then flushes microtasks.
  ///
  /// Set to null to use the default surface size.
  @override
  Future<void> setSurfaceSize(Size? size) {
    return TestAsyncUtils.guard<void>(() async {
      assert(inTest);
      if (_surfaceSize == size) {
        return;
      }
      _surfaceSize = size;
      handleMetricsChanged();
    });
  }

  @override
  ViewConfiguration createViewConfiguration() {
    final double devicePixelRatio = window.devicePixelRatio;
    final Size size = _surfaceSize ?? window.physicalSize / devicePixelRatio;
    return TestViewConfiguration(
      size: size,
      window: window,
    );
  }

  @override
  Completer<bool> get allTestsPassed => _allTestsPassed;
  final Completer<bool> _allTestsPassed = Completer<bool>();

  @override
  List<Failure> get failureMethodsDetails => results.values.whereType<Failure>().toList();

  /// Similar to [WidgetsFlutterBinding.ensureInitialized].
  ///
  /// Returns an instance of the [IntegrationTestWidgetsFlutterBinding], creating and
  /// initializing it if necessary.
  static WidgetsBinding ensureInitialized() {
    if (WidgetsBinding.instance == null) {
      IntegrationTestWidgetsFlutterBinding();
    }
    assert(WidgetsBinding.instance is IntegrationTestWidgetsFlutterBinding);
    return WidgetsBinding.instance!;
  }

  /// Test results that will be populated after the tests have completed.
  ///
  /// Keys are the test descriptions, and values are either [_success] or
  /// a [Failure].
  @visibleForTesting
  Map<String, Object> results = <String, Object>{};

  /// The extra data for the reported result.
  ///
  /// The values in `reportData` must be json-serializable objects or `null`.
  /// If it's `null`, no extra data is attached to the result.
  ///
  /// The default value is `null`.
  @override
  Map<String, dynamic>? reportData;

  /// Manages callbacks received from driver side and commands send to driver
  /// side.
  final CallbackManager callbackManager = driver_actions.callbackManager;

  /// Takes a screenshot.
  ///
  /// On Android, you need to call `convertFlutterSurfaceToImage()`, and
  /// pump a frame before taking a screenshot.
  Future<List<int>> takeScreenshot(String screenshotName) async {
    reportData ??= <String, dynamic>{};
    reportData!['screenshots'] ??= <dynamic>[];
    final Map<String, dynamic> data = await callbackManager.takeScreenshot(screenshotName);
    assert(data.containsKey('bytes'));

    (reportData!['screenshots']! as List<dynamic>).add(data);
    return data['bytes']! as List<int>;
  }

  /// Android only. Converts the Flutter surface to an image view.
  /// Be aware that if you are conducting a perf test, you may not want to call
  /// this method since the this is an expensive operation that affects the
  /// rendering of a Flutter app.
  ///
  /// Once the screenshot is taken, call `revertFlutterImage()` to restore
  /// the original Flutter surface.
  Future<void> convertFlutterSurfaceToImage() async {
    await callbackManager.convertFlutterSurfaceToImage();
  }

  /// The callback function to response the driver side input.
  @visibleForTesting
  Future<Map<String, dynamic>> callback(Map<String, String> params) async {
    return callbackManager.callback(
        params, this /* as IntegrationTestResults */);
  }

  // Emulates the Flutter driver extension, returning 'pass' or 'fail'.
  @override
  void initServiceExtensions() {
    super.initServiceExtensions();

    if (kIsWeb) {
      registerWebServiceExtension(callback);
    }

    registerServiceExtension(name: 'driver', callback: callback);
  }

  @override
  Future<void> runTest(
    Future<void> Function() testBody,
    VoidCallback invariantTester, {
    String description = '',
    Duration? timeout,
  }) async {
    await super.runTest(
      testBody,
      invariantTester,
      description: description,
      timeout: timeout,
    );
    results[description] ??= _success;
  }

  vm.VmService? _vmService;

  /// Initialize the [vm.VmService] settings for the timeline.
  @visibleForTesting
  Future<void> enableTimeline({
    List<String> streams = const <String>['all'],
    @visibleForTesting vm.VmService? vmService,
  }) async {
    assert(streams != null);
    assert(streams.isNotEmpty);
    if (vmService != null) {
      _vmService = vmService;
    }
    if (_vmService == null) {
      final developer.ServiceProtocolInfo info = await developer.Service.getInfo();
      assert(info.serverUri != null);
      _vmService = await vm_io.vmServiceConnectUri(
        'ws://localhost:${info.serverUri!.port}${info.serverUri!.path}ws',
      );
    }
    await _vmService!.setVMTimelineFlags(streams);
  }

  /// Runs [action] and returns a [vm.Timeline] trace for it.
  ///
  /// Waits for the `Future` returned by [action] to complete prior to stopping
  /// the trace.
  ///
  /// The `streams` parameter limits the recorded timeline event streams to only
  /// the ones listed. By default, all streams are recorded.
  /// See `timeline_streams` in
  /// [Dart-SDK/runtime/vm/timeline.cc](https://github.com/dart-lang/sdk/blob/main/runtime/vm/timeline.cc)
  ///
  /// If [retainPriorEvents] is true, retains events recorded prior to calling
  /// [action]. Otherwise, prior events are cleared before calling [action]. By
  /// default, prior events are cleared.
  Future<vm.Timeline> traceTimeline(
    Future<dynamic> Function() action, {
    List<String> streams = const <String>['all'],
    bool retainPriorEvents = false,
  }) async {
    await enableTimeline(streams: streams);
    if (retainPriorEvents) {
      await action();
      return _vmService!.getVMTimeline();
    }

    await _vmService!.clearVMTimeline();
    final vm.Timestamp startTime = await _vmService!.getVMTimelineMicros();
    await action();
    final vm.Timestamp endTime = await _vmService!.getVMTimelineMicros();
    return _vmService!.getVMTimeline(
      timeOriginMicros: startTime.timestamp,
      timeExtentMicros: endTime.timestamp,
    );
  }

  /// This is a convenience method that calls [traceTimeline] and sends the
  /// result back to the host for the [flutter_driver] style tests.
  ///
  /// This records the timeline during `action` and adds the result to
  /// [reportData] with `reportKey`. The [reportData] contains extra information
  /// from the test other than test success/fail. It will be passed back to the
  /// host and be processed by the [ResponseDataCallback] defined in
  /// [integration_test_driver.integrationDriver]. By default it will be written
  /// to `build/integration_response_data.json` with the key `timeline`.
  ///
  /// For tests with multiple calls of this method, `reportKey` needs to be a
  /// unique key, otherwise the later result will override earlier one. Tests
  /// that call this multiple times must also provide a custom
  /// [ResponseDataCallback] to decide where and how to write the output
  /// timelines. For example,
  ///
  /// ```dart
  /// import 'package:integration_test/integration_test_driver.dart';
  ///
  /// Future<void> main() {
  ///   return integrationDriver(
  ///     responseDataCallback: (data) async {
  ///       if (data != null) {
  ///         for (var entry in data.entries) {
  ///           print('Writing ${entry.key} to the disk.');
  ///           await writeResponseData(
  ///             entry.value as Map<String, dynamic>,
  ///             testOutputFilename: entry.key,
  ///           );
  ///         }
  ///       }
  ///     },
  ///   );
  /// }
  /// ```
  ///
  /// The `streams` and `retainPriorEvents` parameters are passed as-is to
  /// [traceTimeline].
  Future<void> traceAction(
    Future<dynamic> Function() action, {
    List<String> streams = const <String>['all'],
    bool retainPriorEvents = false,
    String reportKey = 'timeline',
  }) async {
    final vm.Timeline timeline = await traceTimeline(
      action,
      streams: streams,
      retainPriorEvents: retainPriorEvents,
    );
    reportData ??= <String, dynamic>{};
    reportData![reportKey] = timeline.toJson();
  }

  Future<_GarbageCollectionInfo> _runAndGetGCInfo(Future<void> Function() action) async {
    if (kIsWeb) {
      await action();
      return const _GarbageCollectionInfo();
    }

    final vm.Timeline timeline = await traceTimeline(
      action,
      streams: <String>['GC'],
    );

    final int oldGenGCCount = timeline.traceEvents!.where((vm.TimelineEvent event) {
      return event.json!['cat'] == 'GC' && event.json!['name'] == 'CollectOldGeneration';
    }).length;
    final int newGenGCCount = timeline.traceEvents!.where((vm.TimelineEvent event) {
      return event.json!['cat'] == 'GC' && event.json!['name'] == 'CollectNewGeneration';
    }).length;
    return _GarbageCollectionInfo(
      oldCount: oldGenGCCount,
      newCount: newGenGCCount,
    );
  }

  /// Watches the [FrameTiming] during `action` and report it to the binding
  /// with key `reportKey`.
  ///
  /// This can be used to implement performance tests previously using
  /// [traceAction] and [TimelineSummary] from [flutter_driver]
  Future<void> watchPerformance(
    Future<void> Function() action, {
    String reportKey = 'performance',
  }) async {
    assert(() {
      if (_firstRun) {
        debugPrint(kDebugWarning);
        _firstRun = false;
      }
      return true;
    }());

    // The engine could batch FrameTimings and send them only once per second.
    // Delay for a sufficient time so either old FrameTimings are flushed and not
    // interfering our measurements here, or new FrameTimings are all reported.
    // TODO(CareF): remove this when flush FrameTiming is readly in engine.
    //              See https://github.com/flutter/flutter/issues/64808
    //              and https://github.com/flutter/flutter/issues/67593
    final List<FrameTiming> frameTimings = <FrameTiming>[];
    Future<void> delayForFrameTimings() async {
      int count = 0;
      while (frameTimings.isEmpty) {
        count++;
        await Future<void>.delayed(const Duration(seconds: 2));
        if (count > 20) {
          print('delayForFrameTimings is taking longer than expected...');
        }
      }
    }

    await Future<void>.delayed(const Duration(seconds: 2)); // flush old FrameTimings
    final TimingsCallback watcher = frameTimings.addAll;
    addTimingsCallback(watcher);
    final _GarbageCollectionInfo gcInfo = await _runAndGetGCInfo(action);

    await delayForFrameTimings(); // make sure all FrameTimings are reported
    removeTimingsCallback(watcher);

    final FrameTimingSummarizer frameTimes = FrameTimingSummarizer(
      frameTimings,
      newGenGCCount: gcInfo.newCount,
      oldGenGCCount: gcInfo.oldCount,
    );
    reportData ??= <String, dynamic>{};
    reportData![reportKey] = frameTimes.summary;
  }

  @override
  Timeout get defaultTestTimeout => _defaultTestTimeout ?? super.defaultTestTimeout;

  /// Configures the default timeout for [testWidgets].
  ///
  /// See [TestWidgetsFlutterBinding.defaultTestTimeout] for more details.
  set defaultTestTimeout(Timeout timeout) => _defaultTestTimeout = timeout;
  Timeout? _defaultTestTimeout;

  @override
  void attachRootWidget(Widget rootWidget) {
    // This is a workaround where screenshots of root widgets have incorrect
    // bounds.
    // TODO(jiahaog): Remove when https://github.com/flutter/flutter/issues/66006 is fixed.
    super.attachRootWidget(RepaintBoundary(child: rootWidget));
  }

  @override
  void reportExceptionNoticed(FlutterErrorDetails exception) {
    // This method is called to log errors as they happen, and they will also
    // be eventually logged again at the end of the tests. The superclass
    // behavior is specific to the "live" execution semantics of
    // [LiveTestWidgetsFlutterBinding] so users don't have to wait until tests
    // finish to see the stack traces.
    //
    // Disable this because Integration Tests follow the semantics of
    // [AutomatedTestWidgetsFlutterBinding] that does not log the stack traces
    // live, and avoids the doubly logged stack trace.
    // TODO(jiahaog): Integration test binding should not inherit from
    // `LiveTestWidgetsFlutterBinding` https://github.com/flutter/flutter/issues/81534
  }
}

@immutable
class _GarbageCollectionInfo {
  const _GarbageCollectionInfo({this.oldCount = -1, this.newCount = -1});

  final int oldCount;
  final int newCount;
}
