import 'package:flutter/material.dart';

import '../models/leave_models.dart';
import 'leave_widgets.dart';

// Approve (comment optional) or reject (comment required). Returns the
// comment, '' for an approval without one, or null if they backed out.
Future<String?> showDecisionDialog(BuildContext context, LeaveRequest request, {required bool approve}) {
  final controller = TextEditingController();
  final formKey = GlobalKey<FormState>();

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(approve ? 'Approve leave?' : 'Reject leave?'),
      content: Form(
        key: formKey,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${request.user?.name ?? ''} · ${request.type.name}'),
          Text('${formatDateRange(request.start, request.end)} (${daysLabel(request.days)})'),
          const SizedBox(height: 16),
          TextFormField(
            controller: controller,
            autofocus: !approve,
            maxLines: 3,
            maxLength: 1000,
            decoration: InputDecoration(
              labelText: approve ? 'Comment (optional)' : 'Reason for rejecting',
              border: const OutlineInputBorder(),
            ),
            validator: (v) => !approve && (v == null || v.trim().isEmpty) ? 'Say why you are rejecting this request.' : null,
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
        FilledButton(
          style: approve ? null : FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () {
            if (formKey.currentState!.validate()) Navigator.pop(context, controller.text.trim());
          },
          child: Text(approve ? 'Approve' : 'Reject'),
        ),
      ],
    ),
  );
}
