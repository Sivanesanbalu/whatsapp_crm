-- Allow an account to connect multiple WhatsApp phone numbers while
-- retaining a stable default for new conversations and background sends.

ALTER TABLE whatsapp_config
  ADD COLUMN IF NOT EXISTS is_default BOOLEAN NOT NULL DEFAULT FALSE;

-- Preserve the existing single connection as the account default.
UPDATE whatsapp_config AS current_config
SET is_default = TRUE
WHERE NOT current_config.is_default
  AND NOT EXISTS (
    SELECT 1
    FROM whatsapp_config AS existing_default
    WHERE existing_default.account_id = current_config.account_id
      AND existing_default.is_default
  );

ALTER TABLE whatsapp_config
  DROP CONSTRAINT IF EXISTS whatsapp_config_account_id_key;

-- phone_number_id remains globally unique (migration 013), so a number
-- can still route to exactly one account's webhook configuration.
CREATE UNIQUE INDEX IF NOT EXISTS whatsapp_config_one_default_per_account_idx
  ON whatsapp_config(account_id)
  WHERE is_default;

CREATE OR REPLACE FUNCTION public.set_default_whatsapp_config(p_config_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_account_id UUID;
BEGIN
  SELECT account_id
  INTO v_account_id
  FROM profiles
  WHERE user_id = auth.uid();

  IF v_account_id IS NULL THEN
    RETURN FALSE;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_account_id::TEXT, 0));

  UPDATE whatsapp_config
  SET is_default = FALSE
  WHERE account_id = v_account_id
    AND is_default;

  UPDATE whatsapp_config
  SET is_default = TRUE
  WHERE account_id = v_account_id
    AND id = p_config_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'WhatsApp connection not found for this account';
  END IF;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.set_default_whatsapp_config(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_default_whatsapp_config(UUID) TO authenticated;

ALTER TABLE conversations
  ADD COLUMN IF NOT EXISTS whatsapp_config_id UUID
  REFERENCES whatsapp_config(id) ON DELETE SET NULL;

UPDATE conversations AS conversation
SET whatsapp_config_id = config.id
FROM whatsapp_config AS config
WHERE conversation.account_id = config.account_id
  AND config.is_default
  AND conversation.whatsapp_config_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_conversations_whatsapp_config
  ON conversations(whatsapp_config_id);