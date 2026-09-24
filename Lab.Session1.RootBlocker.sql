/*
  LAB ONLY. Run in query window 1 after Lab.Setup.sql.
  This transaction holds a row lock while the registered timeout process runs.
  If the child is terminated, the wrapper returns and the CATCH/cleanup path rolls back.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutionId uniqueidentifier;

BEGIN TRY
    BEGIN TRANSACTION;
    UPDATE xt.LabBlockingTarget SET Value = Value + 1 WHERE Id = 1;

    EXEC xt.usp_RunRegisteredCommand
        @ProfileId = N'LabHang',
        @ArgumentsJson = N'[]',
        @WorkingDirectory = NULL,
        @ExecutionId = @ExecutionId OUTPUT;

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    SELECT @ExecutionId AS ExecutionId, ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage;
    THROW;
END CATCH;

SELECT @ExecutionId AS ExecutionId;

