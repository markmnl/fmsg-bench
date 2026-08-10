-- Extra example.com users for multi-participant scenarios (p5 needs
-- four remote recipients; seed-example.sql only creates bob and carol).
\connect fmsgid

INSERT INTO address (address_lower, address, display_name)
VALUES ('@dave@example.com', '@Dave@example.com', 'Dave')
ON CONFLICT (address_lower) DO UPDATE
SET address = EXCLUDED.address,
    display_name = EXCLUDED.display_name;

INSERT INTO address (address_lower, address, display_name)
VALUES ('@erin@example.com', '@Erin@example.com', 'Erin')
ON CONFLICT (address_lower) DO UPDATE
SET address = EXCLUDED.address,
    display_name = EXCLUDED.display_name;
