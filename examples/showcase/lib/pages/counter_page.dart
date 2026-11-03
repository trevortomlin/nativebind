import 'dart:async';

import 'package:flutter/material.dart';

import '../nativebind/nativebind_modules.dart';

/// Counter: a read-only value, a writable value with a range, a signal and calls.
class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  final counter = Counter.instance;
  late final StreamSubscription<int> _milestones;

  @override
  void initState() {
    super.initState();
    // A BoundSignal is a Stream.
    _milestones = counter.milestone.listen((n) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reached $n!')));
    });
  }

  @override
  void dispose() {
    _milestones.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Rebuilds whenever C++ assigns `count`.
          ValueListenableBuilder(
            valueListenable: counter.count,
            builder: (context, count, _) => Text('$count', style: text.displayLarge),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(onPressed: counter.increment, icon: const Icon(Icons.add), label: const Text('Add')),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: counter.reset, child: const Text('Reset')),
            ],
          ),
          const SizedBox(height: 32),
          // `step` is writable: the slider's range comes from C++ (.min/.max).
          ValueListenableBuilder(
            valueListenable: counter.step,
            builder: (context, step, _) {
              final meta = counter.step.meta;
              return SizedBox(
                width: 320,
                child: Column(children: [
                  Text('${meta.label ?? 'Step'}: $step'),
                  Slider(
                    value: step.toDouble(),
                    min: meta.min,
                    max: meta.max,
                    divisions: (meta.max - meta.min).round(),
                    onChanged: (v) => counter.step.value = v.round(),
                  ),
                ]),
              );
            },
          ),
        ],
      ),
    );
  }
}
