// MINERVA Neo4j 5.x schema — constraints, indexes, and conventions.
// Apply with: cypher-shell -f specs/graph-schema.cypher

// ---------- Uniqueness constraints ----------
CREATE CONSTRAINT paper_id_version IF NOT EXISTS
FOR (p:Paper) REQUIRE (p.article_id, p.version) IS NODE KEY;

CREATE CONSTRAINT chunk_id IF NOT EXISTS
FOR (c:Chunk) REQUIRE c.chunk_id IS UNIQUE;

CREATE CONSTRAINT entity_id IF NOT EXISTS
FOR (e:Entity) REQUIRE e.id IS UNIQUE;

CREATE CONSTRAINT dataset_id IF NOT EXISTS
FOR (d:Dataset) REQUIRE d.id IS UNIQUE;

CREATE CONSTRAINT method_id IF NOT EXISTS
FOR (m:Method) REQUIRE m.id IS UNIQUE;

CREATE CONSTRAINT cohort_id IF NOT EXISTS
FOR (c:Cohort) REQUIRE c.id IS UNIQUE;

// ---------- Range indexes used by retrieval filters ----------
CREATE INDEX paper_current IF NOT EXISTS FOR (p:Paper) ON (p.is_current);
CREATE INDEX paper_year IF NOT EXISTS FOR (p:Paper) ON (p.year);
CREATE INDEX paper_doi IF NOT EXISTS FOR (p:Paper) ON (p.doi);
CREATE INDEX paper_pmid IF NOT EXISTS FOR (p:Paper) ON (p.pmid);
CREATE INDEX paper_retracted IF NOT EXISTS FOR (p:Paper) ON (p.retracted);
CREATE INDEX chunk_current IF NOT EXISTS FOR (c:Chunk) ON (c.is_current);
CREATE INDEX chunk_hash IF NOT EXISTS FOR (c:Chunk) ON (c.chunk_hash);
CREATE INDEX chunk_validity IF NOT EXISTS FOR (c:Chunk) ON (c.valid_from, c.valid_to);
CREATE INDEX entity_type IF NOT EXISTS FOR (e:Entity) ON (e.type);
CREATE INDEX entity_name IF NOT EXISTS FOR (e:Entity) ON (e.name_normalized);
CREATE INDEX rel_conf IF NOT EXISTS FOR ()-[r:REL]-() ON (r.confidence);
CREATE INDEX rel_article IF NOT EXISTS FOR ()-[r:REL]-() ON (r.article_id, r.version);

// ---------- Vector index (Titan Text Embeddings V2, 1024-d, cosine) ----------
CREATE VECTOR INDEX chunk_embedding IF NOT EXISTS
FOR (c:Chunk) ON (c.embedding)
OPTIONS { indexConfig: {
  `vector.dimensions`: 1024,
  `vector.similarity_function`: 'cosine'
}};

// Blue/green slot for an embedding-model upgrade (built in background, switched via SSM).
// CREATE VECTOR INDEX chunk_embedding_v2 IF NOT EXISTS FOR (c:Chunk) ON (c.embedding_v2) ...

// ---------- Full-text (Lucene / BM25) indexes ----------
CREATE FULLTEXT INDEX chunk_text IF NOT EXISTS
FOR (c:Chunk) ON EACH [c.text, c.section_heading]
OPTIONS { indexConfig: { `fulltext.analyzer`: 'english' } };

CREATE FULLTEXT INDEX paper_text IF NOT EXISTS
FOR (p:Paper) ON EACH [p.title, p.abstract]
OPTIONS { indexConfig: { `fulltext.analyzer`: 'english' } };

CREATE FULLTEXT INDEX entity_aliases IF NOT EXISTS
FOR (e:Entity) ON EACH [e.name, e.aliases_text];

// ---------- Node property conventions ----------
// (:Paper)   article_id, version, is_current, valid_from, valid_to, title, abstract, year,
//            venue, doi, pmid, pmcid, arxiv_id, authors (list), source, open_access,
//            retracted, retraction_notice_id, citation_count, content_hash, meta_hash,
//            chunking_version, extraction_prompt_version
// (:Chunk)   chunk_id, chunk_hash, text, section, section_heading, position, token_count,
//            embedding (float[1024]), embedding_model, is_current, valid_from, valid_to,
//            suspicious (bool — injection-like text flagged at ingestion)
// (:Entity)  id (ontology-prefixed e.g. HGNC:1100, MESH:D001943, CHEBI:12345, UMLS:C0006142,
//            or CAND:<ulid> for unlinked candidates), name, name_normalized, type
//            (Gene|Protein|Disease|Chemical|Organism|Method|Dataset|Cohort|Phenotype|Anatomy),
//            aliases (list), aliases_text (joined for full-text), ontology, linked (bool)
// (:Dataset) id, name, source_url, accession
// (:Method)  id, name
// (:Cohort)  id, name, size, description

// ---------- Relationship conventions ----------
// (Paper)-[:HAS_CHUNK]->(Chunk)                          shared chunk nodes across versions
// (Paper)-[:SUPERSEDES]->(Paper)                          version chain (newer -> older)
// (Paper)-[:CORRECTED_BY]->(Paper)                        erratum / correction notice
// (Paper)-[:CITES]->(Paper)                               from parsed references (resolved by DOI/PMID)
// (Paper)-[:MENTIONS {count, chunk_ids}]->(Entity)
// (Paper)-[:USES_DATASET]->(Dataset)
// (Paper)-[:USES_METHOD]->(Method)
// (Paper)-[:STUDIES_COHORT]->(Cohort)
// (Entity)-[:REL {predicate, article_id, version, confidence, evidence_chunk_ids,
//                 negated, hedged, retracted}]->(Entity)
//   predicate ∈ ASSOCIATED_WITH | TREATS | INHIBITS | ACTIVATES | CAUSES | BIOMARKER_FOR |
//               INTERACTS_WITH | PART_OF | EVALUATED_ON | COMPARED_WITH | CONTRADICTS | SUPPORTS
//   A single REL label with a `predicate` property keeps the schema stable while the
//   predicate vocabulary evolves; indexes on (article_id, version) make the version flip cheap.

// ---------- Retrieval helper: current-version filter ----------
// Default:   c.is_current = true AND p.is_current = true AND p.retracted = false
// as_of:     c.valid_from <= $as_of AND (c.valid_to IS NULL OR c.valid_to > $as_of)
//            p.valid_from <= $as_of AND (p.valid_to IS NULL OR p.valid_to > $as_of)
