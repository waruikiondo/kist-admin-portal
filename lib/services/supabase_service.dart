import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/schemas.dart';

class SupabaseService {
  final _supabase = Supabase.instance.client;

  // --- 1. SYNC TOOLS (Cloud is Master) ---
  Future<void> syncTools(List<Tool> localTools) async {
    // In a real app, this logic is complex (conflict resolution).
    // For this MVP, we will simpler: If Cloud has data, we pull it. 
    // If Cloud is empty, we push our local data (Initial Setup).
    
    final response = await _supabase.from('tools').select();
    
    if (response.isEmpty && localTools.isNotEmpty) {
      // Cloud is empty, Push Local Data (Initial Upload)
      final dataToUpload = localTools.map((t) => {
        'uuid': t.uuid,
        'name': t.name,
        'category': t.category,
        'is_available': t.isAvailable,
      }).toList();
      
      await _supabase.from('tools').insert(dataToUpload);
    }
  }

  // --- 2. RECORD TRANSACTION (Real-time) ---
  Future<void> logTransaction(TransactionLog log) async {
    // When we issue a tool locally, we also tell the cloud immediately
    try {
      await _supabase.from('transaction_logs').insert({
        'tool_name': log.toolName,
        'issued_to': log.issuedTo,             // UPDATED: Replaced student_name
        'is_group_issue': log.isGroupIssue,    // NEW: Handles Group vs Single Student
        'time_borrowed': log.timeBorrowed.toIso8601String(),
        'is_returned': false,
        'status': 'GOOD',
      });
      
      // Also update the tool status in the cloud
      await _supabase.from('tools')
        .update({'is_available': false})
        .eq('name', log.toolName); // Ideally use UUID here
        
    } catch (e) {
      print("Offline: Transaction saved locally, will sync later.");
    }
  }

  // --- 3. MARK LOST ITEM (For your Report) ---
  Future<void> reportLostItem(String toolName, String issuedTo, bool isGroupIssue) async {
    await _supabase.from('transaction_logs').insert({
      'tool_name': toolName,
      'issued_to': issuedTo,               // UPDATED
      'is_group_issue': isGroupIssue,      // NEW
      'time_borrowed': DateTime.now().toIso8601String(),
      'is_returned': true, // Transaction is "closed"
      'status': 'LOST',    // BUT it is marked LOST
    });
  }

  // --- 4. THE LIVE QUEUE STREAM (For QR Code Requests) ---
  // This listens to the 'tool_requests' table and yields live updates
  Stream<List<Map<String, dynamic>>> get liveToolRequests {
    return _supabase
        .from('tool_requests')
        .stream(primaryKey: ['id'])
        .eq('status', 'PENDING') // Only show requests that haven't been issued yet
        .order('created_at', ascending: true); // Oldest requests at the top
  }

  // --- 5. APPROVE A QR REQUEST ---
  Future<void> approveRequest(int requestId) async {
    await _supabase
        .from('tool_requests')
        .update({'status': 'ISSUED'})
        .eq('id', requestId);
  }

  // --- 6. REJECT/CANCEL A QR REQUEST ---
  Future<void> rejectRequest(int requestId) async {
    await _supabase
        .from('tool_requests')
        .update({'status': 'CANCELLED'})
        .eq('id', requestId);
  }
}