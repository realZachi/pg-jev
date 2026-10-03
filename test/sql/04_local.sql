-- Local Jev-compatible servers (stuntd, laya-server): no API key is needed unless jev.api_url is *.typesafe.ai.
-- The mock accepts requests without an Authorization header under /local/.
\set VERBOSITY terse
SET jev.notices = off;
SET jev.api_key = '';
CREATE TABLE local_cities (id int, name text, country text);
INSERT INTO local_cities VALUES (1, 'Berlin', 'Germany'), (2, 'Tokyo', 'Japan'), (3, 'Munich', 'Germany');

-- A local server without auth: requests are sent without an Authorization header
SET jev.api_url = 'http://127.0.0.1:8765/local/v1/systemone';
SELECT name FROM local_cities WHERE jev(local_cities, 'the country is Germany') ORDER BY id;
SELECT name, jev_choice(local_cities, 'which team', ARRAY['red', 'blue']) AS team FROM local_cities ORDER BY id;

-- A key, when set, is still sent to a local server
SET jev.api_key = 'wrong-key';
SELECT jev(local_cities, 'the country is Japan') FROM local_cities;
SET jev.api_key = 'test-key';
SELECT name FROM local_cities WHERE jev(local_cities, 'the city is Tokyo') ORDER BY id;

-- An endpoint that does require a key reports its own error instead of the missing-key error
SET jev.api_key = '';
SET jev.api_url = 'http://127.0.0.1:8765/v1/systemone';
SELECT jev(local_cities, 'the city is Lima') FROM local_cities;

-- Any *.typesafe.ai host still needs a key, checked before any request is made
SET jev.api_url = 'https://EU.api.typesafe.ai/v1/systemone';
SELECT jev(local_cities, 'the city is Lima') FROM local_cities;
SET jev.api_url = 'https://typesafe.ai/v1/systemone';
SELECT jev(local_cities, 'the city is Lima') FROM local_cities;
