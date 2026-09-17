\set VERBOSITY terse
SET jev.api_url = 'http://127.0.0.1:8765/v1/systemone';
SET jev.notices = off;
CREATE TABLE things (id int, v text);
INSERT INTO things VALUES (1, 'a');

-- No key configured anywhere
SET jev.api_key = '';
SELECT jev(things, 'anything') FROM things;

-- Non-retryable HTTP errors surface as SQL errors
SET jev.api_key = 'wrong-key';
SELECT jev(things, 'anything') FROM things;
SET jev.api_key = 'test-key';
SELECT jev(things, 'please trigger422') FROM things;

-- Unknown question kind
SELECT jev_eval(things, 'anything', 'bogus', NULL) FROM things;

-- Errors are counted, and the session keeps working afterwards
SELECT (jev_stats()->>'errors')::int AS errors;
SELECT jev(things, 'the value is a') FROM things;
