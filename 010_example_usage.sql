/* Replace these examples with site-owned profiles and executables. */

MERGE xt.CommandProfile AS target
USING (VALUES
    (N'ExampleEcho', CONVERT(bit, 0), N'Non-production wrapper smoke test', N'Database Engineering')
) AS source(ProfileId, Enabled, Description, OwnerName)
ON target.ProfileId = source.ProfileId
WHEN MATCHED THEN
    UPDATE SET Description = source.Description, OwnerName = source.OwnerName
WHEN NOT MATCHED THEN
    INSERT(ProfileId, Enabled, Description, OwnerName)
    VALUES(source.ProfileId, source.Enabled, source.Description, source.OwnerName);
GO

/* Enable only after command-profiles.json and NTFS permissions are deployed and reviewed. */
-- UPDATE xt.CommandProfile SET Enabled = 1 WHERE ProfileId = N'ExampleEcho';
-- UPDATE xt.ConfigInstance SET Enabled = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = ORIGINAL_LOGIN() WHERE ConfigId = 1;
GO

DECLARE @ExecutionId uniqueidentifier;

EXEC xt.usp_RunRegisteredCommand
    @ProfileId = N'ExampleEcho',
    @ArgumentsJson = N'["hello-from-sql"]',
    @WorkingDirectory = NULL,
    @ExecutionId = @ExecutionId OUTPUT;

SELECT @ExecutionId AS ExecutionId;
GO

SELECT TOP (100)
    e.ExecutionId, e.InstanceName, e.DatabaseName, e.SessionId, e.ProfileId,
    e.State, e.RequestedUtc, e.StartedUtc, e.LastHeartbeatUtc, e.CompletedUtc,
    e.ProcessId, e.ExitCode, e.ErrorNumber, e.ErrorMessage,
    p.ParentProcessId, p.CreationTimeUtc, p.ImagePath, p.OwnerSid,
    p.CommandHash, p.LauncherVersion
FROM xt.ExecutionRegistry AS e
LEFT JOIN xt.ProcessEvidence AS p ON p.ExecutionId = e.ExecutionId
ORDER BY e.RequestedUtc DESC;
GO

