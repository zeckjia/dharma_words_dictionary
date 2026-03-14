-- ============================================================
-- Fuzzy search for the Dharma Words Dictionary
--
-- Prerequisites (run once as superuser / Supabase dashboard):
--   CREATE EXTENSION IF NOT EXISTS pg_trgm;
--
-- Recommended indexes for performance:
--   CREATE INDEX IF NOT EXISTS idx_dictionary_chn_trgm
--     ON public.dictionary USING GIN (chn gin_trgm_ops);
--   CREATE INDEX IF NOT EXISTS idx_dictionary_eng_trgm
--     ON public.dictionary USING GIN (eng gin_trgm_ops);
--   CREATE INDEX IF NOT EXISTS idx_dictionary_comment_trgm
--     ON public.dictionary USING GIN (comment gin_trgm_ops);
-- ============================================================

DROP FUNCTION IF EXISTS lookup_words(text, integer);
CREATE OR REPLACE FUNCTION public.lookup_words(
  info      text    DEFAULT NULL,
  p_limit   integer DEFAULT 50
)
RETURNS TABLE (
  chn       text,
  eng       text,
  from_src  text,
  src       text,
  type      text,
  comment   text,
  relevance double precision
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    d.chn,
    d.eng,
    d.from_src,
    d.src,
    d.type,
    d.comment,
    (
      -- Tier 1 · Exact full match (case-insensitive)
      CASE WHEN d.chn     ILIKE info THEN 100.0 ELSE 0.0 END
      + CASE WHEN d.eng   ILIKE info THEN 100.0 ELSE 0.0 END

      -- Tier 2 · Starts-with
      + CASE WHEN d.chn   ILIKE (info || '%') THEN 30.0 ELSE 0.0 END
      + CASE WHEN d.eng   ILIKE (info || '%') THEN 30.0 ELSE 0.0 END

      -- Tier 3 · Substring (original ILIKE behaviour)
      + CASE WHEN d.chn     ILIKE ('%' || info || '%') THEN 20.0 ELSE 0.0 END
      + CASE WHEN d.eng     ILIKE ('%' || info || '%') THEN 15.0 ELSE 0.0 END
      + CASE WHEN d.comment ILIKE ('%' || info || '%') THEN  5.0 ELSE 0.0 END

      -- Tier 4 · Fuzzy / trigram similarity (typo-tolerant)
      --   word_similarity(needle, haystack) → how well the needle matches
      --   any contiguous word sequence in the haystack (0–1).
      --   Multiplied by 25 so a perfect word match (~1.0) contributes +25.
      + greatest(
          word_similarity(info, d.chn),
          word_similarity(info, d.eng)
        ) * 25.0
    )::double precision AS relevance

  FROM public.dictionary d
  WHERE
    info IS NOT NULL
    AND (
      -- Fast substring path (benefits from a regular trigram GIN index)
      d.chn     ILIKE ('%' || info || '%')
      OR d.eng     ILIKE ('%' || info || '%')
      OR d.comment ILIKE ('%' || info || '%')

      -- Fuzzy path: catch near-matches / typos
      -- Threshold 0.3 is a good balance; lower = more results, higher = stricter
      OR word_similarity(info, d.chn) > 0.3
      OR word_similarity(info, d.eng) > 0.3
    )

  ORDER BY relevance DESC, d.created_at DESC
  LIMIT p_limit;
$$;
