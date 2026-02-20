import 'package:isar/isar.dart';

part 'schemas.g.dart';

@collection
class Tool {
  Id id = Isar.autoIncrement;
  @Index(unique: true)
  late String uuid;
  late String name;
  late String category;
  bool isAvailable;

  Tool({
    required this.uuid,
    required this.name,
    required this.category,
    this.isAvailable = true,
  });
}

@collection
class Student {
  Id id = Isar.autoIncrement;
  @Index(unique: true)
  late String admNumber;
  late String name;
  String? groupName;

  Student({
    required this.admNumber,
    required this.name,
    this.groupName,
  });
}

@collection
class LabGroup {
  Id id = Isar.autoIncrement;
  @Index(unique: true)
  late String name;

  LabGroup({required this.name});
}

@collection
class TransactionLog {
  Id id = Isar.autoIncrement;
  late String toolName;
  late String issuedTo;
  bool isGroupIssue;
  late DateTime timeBorrowed;
  DateTime? timeReturned;
  bool isReturned;

  TransactionLog({
    required this.toolName,
    required this.issuedTo,
    this.isGroupIssue = false,
    required this.timeBorrowed,
    this.isReturned = false,
  });
}