import 'package:flutter/material.dart';

import '../engine/form_engine.dart';
import '../widgets/question_field.dart';

// Last look before finalizing: problems first, then every answer shown.
// Pops true when the user finalizes, false/null to go back and edit.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key, required this.engine, required this.title});

  final FormEngine engine;
  final String title;

  @override
  Widget build(BuildContext context) {
    final issues = engine.validate();
    final items = engine.renderItems();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text('Review: $title')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (issues.isNotEmpty)
            Card(
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${issues.length} question(s) need attention', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    for (final i in issues)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('• ${_where(i.frames)}${engine.interpolate(i.node.label.isEmpty ? i.node.name : i.node.label, i.frames)}: ${i.message}'),
                      ),
                  ],
                ),
              ),
            )
          else
            Card(
              color: scheme.secondaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('All required questions are answered. Check the answers below, then finalize.'),
              ),
            ),
          const SizedBox(height: 8),
          for (final item in items) _row(context, item),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Back to form'))),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: issues.isEmpty ? () => Navigator.pop(context, true) : null,
                child: const Text('Finalize'),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  String _where(List<RepeatFrame> frames) => frames.isEmpty ? '' : '${frames.map((f) => '${f.name} ${f.index + 1}').join(' › ')} › ';

  Widget _row(BuildContext context, RenderItem item) {
    final indent = (item.depth * 12).clamp(0, 36).toDouble();
    final node = item.node;
    switch (item.kind) {
      case RenderKind.group:
        return Padding(
          padding: EdgeInsets.fromLTRB(indent, 16, 0, 4),
          child: Text(engine.interpolate(node.label, item.frames), style: Theme.of(context).textTheme.titleMedium),
        );
      case RenderKind.repeatInstance:
        return Padding(
          padding: EdgeInsets.fromLTRB(indent, 12, 0, 4),
          child: Text('${node.label.isEmpty ? node.name : node.label} ${item.frames.last.index + 1}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        );
      case RenderKind.repeatAdd:
        return const SizedBox.shrink();
      case RenderKind.question:
        if (!node.hasValue) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.fromLTRB(indent, 4, 0, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Text(engine.interpolate(node.label.isEmpty ? node.name : node.label, item.frames),
                    style: const TextStyle(color: Colors.grey)),
              ),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: Text(displayAnswer(node, engine.valueOf(item.frames, node.name)))),
            ],
          ),
        );
    }
  }
}
