/* LAB ONLY. Run in query window 2 while query window 1 is waiting. */
SET LOCK_TIMEOUT 900000;

BEGIN TRY
    BEGIN TRANSACTION;
    UPDATE xt.LabBlockingTarget SET Value = Value + 10 WHERE Id = 1;
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

