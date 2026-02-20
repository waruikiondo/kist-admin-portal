import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  final _supabase = Supabase.instance.client;

  Stream<List<Map<String, dynamic>>> get liveToolRequests {
    return _supabase
        .from('tool_requests')
        .stream(primaryKey: ['id'])
        .eq('status', 'PENDING')
        .order('created_at', ascending: true);
  }

  Future<void> approveRequest(int requestId) async {
    await _supabase
        .from('tool_requests')
        .update({'status': 'ISSUED'})
        .eq('id', requestId);
  }

  Future<void> rejectRequest(int requestId) async {
    await _supabase
        .from('tool_requests')
        .update({'status': 'CANCELLED'})
        .eq('id', requestId);
  }
}