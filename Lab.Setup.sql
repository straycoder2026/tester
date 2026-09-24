/* LAB ONLY. Run in the monitor database. */
SET NOCOUNT ON;

IF OBJECT_ID(N'xt.LabBlockingTarget', N'U') IS NULL
BEGIN
    CREATE TABLE xt.LabBlockingTarget
    (
        Id int NOT NULL CONSTRAINT PK_LabBlockingTarget PRIMARY KEY,
        Value int NOT NULL
    );
    INSERT xt.LabBlockingTarget(Id, Value) VALUES(1, 0);
END;

MERGE xt.CommandProfile AS target
USING (VALUES(N'LabHang', CONVERT(bit, 1), N'LAB ONLY controlled timeout process', N'Database Engineering'))
      AS source(ProfileId, Enabled, Description, OwnerName)
ON target.ProfileId = source.ProfileId
WHEN MATCHED THEN UPDATE SET Enabled=source.Enabled, Description=source.Description, OwnerName=source.OwnerName
WHEN NOT MATCHED THEN INSERT(ProfileId, Enabled, Description, OwnerName)
VALUES(source.ProfileId, source.Enabled, source.Description, source.OwnerName);

UPDATE xt.ConfigInstance
SET Enabled = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = ORIGINAL_LOGIN()
WHERE ConfigId = 1;

UPDATE xt.ConfigTermination
SET Enabled = 1,
    OperatingMode = 'AuditOnly',
    MinimumExecutionSeconds = 60,
    MinimumBlockedSeconds = 30,
    MinimumBlockedSessions = 1,
    MinimumObservations = 2,
    MinimumStableObservations = 2,
    UpdatedUtc = SYSUTCDATETIME(),
    UpdatedBy = ORIGINAL_LOGIN()
WHERE ConfigId = 1;

SELECT * FROM xt.ConfigInstance;
SELECT * FROM xt.ConfigTermination;
SELECT * FROM xt.CommandProfile WHERE ProfileId = N'LabHang';

