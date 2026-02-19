import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import '../data/schemas.dart';

class InventoryService extends ChangeNotifier {
  late Isar isar;
  List<Tool> allTools = [];
  List<TransactionLog> activeLoans = [];

  // Initialize the Offline Database
  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    isar = await Isar.open(
      [ToolSchema, StudentSchema, TransactionLogSchema],
      directory: dir.path,
    );
    
    // Load initial data
    await refreshData();
  }

  Future<void> refreshData() async {
    allTools = await isar.tools.where().findAll();
    activeLoans = await isar.transactionLogs.filter().isReturnedEqualTo(false).findAll();
    notifyListeners();
  }

  // --- FAST ACTION: Add a new tool (One time setup) ---
  Future<void> addTool(String name, String category) async {
    final newTool = Tool(
      uuid: DateTime.now().millisecondsSinceEpoch.toString(), // Simple unique ID
      name: name,
      category: category,
    );

    await isar.writeTxn(() async {
      await isar.tools.put(newTool);
    });
    await refreshData();
  }

  // --- FAST ACTION: Issue Tool to Student ---
  Future<void> issueTool(Tool tool, String studentName) async {
    if (!tool.isAvailable) return;

    final transaction = TransactionLog(
      toolName: tool.name,
      studentName: studentName,
      timeBorrowed: DateTime.now(),
    );

    await isar.writeTxn(() async {
      // 1. Mark tool as taken
      tool.isAvailable = false;
      tool.currentHolderName = studentName;
      await isar.tools.put(tool);

      // 2. Create record
      await isar.transactionLogs.put(transaction);
    });

    await refreshData();
  }

  // --- FAST ACTION: Return Tool ---
  Future<void> returnTool(TransactionLog transaction, bool isDamaged) async {
    await isar.writeTxn(() async {
      // 1. Mark transaction as closed
      transaction.isReturned = true;
      transaction.timeReturned = DateTime.now();
      await isar.transactionLogs.put(transaction);

      // 2. Free up the tool
      // Find the tool by name (In a real app, use UUID)
      final tool = await isar.tools.filter().nameEqualTo(transaction.toolName).findFirst();
      if (tool != null) {
        tool.isAvailable = !isDamaged; // If damaged, don't make available
        tool.currentHolderName = null;
        await isar.tools.put(tool);
      }
    });
    await refreshData();
  }
}