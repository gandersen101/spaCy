import numpy

from ..tokens import Token
from ..tokens.doc cimport Doc
from ..attrs import IDS
from .align cimport Alignment
from .annotation import TokenAnnotation, DocAnnotation
from .iob_utils import biluo_to_iob, biluo_tags_from_offsets, biluo_tags_from_doc
from .align import Alignment
from ..errors import Errors, AlignmentError


cpdef Doc annotations2doc(Doc predicted, tok_annot, doc_annot):
    # TODO: Improve and test this
    words = tok_annot.get("ORTH", [tok.text for tok in predicted])
    attrs, array = _annot2array(predicted.vocab, tok_annot, doc_annot)
    output = Doc(predicted.vocab, words=words)
    if array.size:
        output = output.from_array(attrs, array)
    output.cats.update(doc_annot.get("cats", {}))
    return output


cdef class NewExample:
    def __init__(self, Doc predicted, Doc reference, *, Alignment alignment=None):
        """ Doc can either be text, or an actual Doc """
        msg = "Example.__init__ got None for '{arg}'. Requires Doc."
        if predicted is None:
            raise TypeError(msg.format(arg="predicted"))
        if reference is None:
            raise TypeError(msg.format(arg="reference"))
        self.x = predicted
        self.y = reference
        self._alignment = alignment

    property predicted:
        def __get__(self):
            return self.x

        def __set__(self, doc):
            self.x = doc
    
    property reference:
        def __get__(self):
            return self.y

        def __set__(self, doc):
            self.y = doc
 
    @classmethod
    def from_dict(cls, Doc predicted, dict example_dict):
        if example_dict is None:
            raise ValueError("Example.from_dict expected dict, received None")
        if not isinstance(predicted, Doc):
            raise TypeError(f"Argument 1 should be Doc. Got {type(predicted)}")
        example_dict = _fix_legacy_dict_data(predicted, example_dict)
        tok_dict, doc_dict = _parse_example_dict_data(example_dict)
        return NewExample(
            predicted,
            annotations2doc(predicted, tok_dict, doc_dict)
        )
    
    @property
    def alignment(self):
        if self._alignment is None:
            if self.doc is None:
                return None
            spacy_words = [token.orth_ for token in self.predicted]
            gold_words = [token.orth_ for token in self.reference]
            if gold_words == []:
                gold_words = spacy_words
            self._alignment = Alignment(spacy_words, gold_words)
        return self._alignment

    def get_aligned(self, field):
        """Return an aligned array for a token attribute."""
        # TODO: This is probably wrong. I just bashed this out and there's probably
        # all sorts of edge-cases.
        alignment = self.alignment
        i2j_multi = alignment.i2j_multi
        gold_to_cand = alignment.gold_to_cand
        cand_to_gold = alignment.cand_to_gold

        gold_values = self.reference.to_array([field])
        output = []
        for i, gold_i in enumerate(cand_to_gold):
            if self.predicted[i].text.isspace():
                output.append(None)
            elif gold_i is None:
                if i in i2j_multi:
                    output.append(gold_values[i2j_multi[i]])
                else:
                    output.append(None)
            else:
                output.append(gold_values[gold_i])
        return output

    def to_dict(self):
        return {
            "doc_annotation": {
                "cats": dict(self.reference.cats),
                "links": [], # TODO
            },
            "token_annotation": {
                "ids": [t.i+1 for t in self.reference],
                "words": [t.text for t in self.reference],
                "tags": [t.tag_ for t in self.reference],
                "lemmas": [t.lemma_ for t in self.reference],
                "pos": [t.pos_ for t in self.reference],
                "morphs": [t.morph_ for t in self.reference],
                "heads": [t.head.i for t in self.reference],
                "deps": [t.dep_ for t in self.reference],
                "sent_starts": [int(bool(t.is_sent_start)) for t in self.reference],
                "entities": biluo_tags_from_doc(self.reference)
            }
        }

    def split_sents(self):
        """ Split the token annotations into multiple Examples based on
        sent_starts and return a list of the new Examples"""
        if not self.reference.is_sentenced:
            return [self]
        # TODO: Do this for misaligned somehow?
        predicted_words = [t.text for t in self.predicted]
        reference_words = [t.text for t in self.reference]
        if predicted_words != reference_words:
            raise NotImplementedError("TODO: Implement this")
        # Implement the easy case.
        output = []
        cls = self.__class__
        for sent in self.reference.sents:
            # I guess for misaligned we just need to use the gold_to_cand?
            output.append(
                cls(
                    self.predicted[sent.start : sent.end + 1].as_doc(),
                    sent.as_doc()
                )
            )
        return output

    def text(self):
        return self.x.text


def _annot2array(vocab, tok_annot, doc_annot):
    attrs = []
    values = []

    for key, value in doc_annot.items():
        if key == "entities":
            words = tok_annot["ORTH"]
            ent_iobs, ent_types = _parse_ner_tags(vocab, words, value)
            tok_annot["ENT_IOB"] = ent_iobs
            tok_annot["ENT_TYPE"] = ent_types
        elif key == "links":
            entities = doc_annot.get("entities", {})
            if value and not entities:
                raise ValueError(Errors.E984)
            ent_kb_ids = _parse_links(vocab, words, value, entities)
            tok_annot["ENT_KB_ID"] = ent_kb_ids
        elif key == "cats":
            pass
        else:
            raise ValueError(f"Unknown doc attribute: {key}")

    for key, value in tok_annot.items():
        if key not in IDS:
            raise ValueError(f"Unknown token attribute: {key}")
        elif key == "ORTH":
            pass
        elif key == "HEAD":
            attrs.append(key)
            values.append([h-i for i, h in enumerate(value)])
        elif key == "SENT_START":
            attrs.append(key)
            values.append(value)
        elif key == "MORPH":
            attrs.append(key)
            values.append([vocab.morphology.add(v) for v in value])
        elif key == "ENT_IOB":
            iob_strings = Token.iob_strings()
            attrs.append(key)
            try:
                values.append([iob_strings.index(v) for v in value])
            except ValueError:
                raise ValueError(Errors.E985.format(values=iob_strings, value=values))
        else:
            attrs.append(key)
            values.append([vocab.strings.add(v) for v in value])

    array = numpy.asarray(values, dtype="uint64")
    return attrs, array.T


def _parse_example_dict_data(example_dict):
    return (
        example_dict["token_annotation"],
        example_dict["doc_annotation"]
    )


def _fix_legacy_dict_data(predicted, example_dict):
    token_dict = example_dict.get("token_annotation", {})
    doc_dict = example_dict.get("doc_annotation", {})
    for key, value in example_dict.items():
        if key in ("token_annotation", "doc_annotation"):
            pass
        elif key == "ids":
            pass
        elif key in ("cats", "links") and value:
            doc_dict[key] = value
        elif key in ("ner", "entities") and value:
            doc_dict["entities"] = value
        else:
            token_dict[key] = value
    # Remap keys
    remapping = {
        "words": "ORTH",
        "tags": "TAG",
        "pos": "POS",
        "lemmas": "LEMMA",
        "deps": "DEP",
        "heads": "HEAD",
        "sent_starts": "SENT_START",
        "morphs": "MORPH",
    }
    old_token_dict = token_dict
    token_dict = {}
    for key, value in old_token_dict.items():
        if key in ("text", "ids", "entities", "ner", "brackets"):
            pass
        elif key in remapping:
            token_dict[remapping[key]] = value
        else:
            raise ValueError(f"Unknown attr: {key}")
    if "HEAD" in token_dict and "SENT_START" in token_dict:
        # If heads are set, we don't also redundantly specify SENT_START.
        token_dict.pop("SENT_START")
    return {
        "token_annotation": token_dict,
        "doc_annotation": doc_dict
    }


def _parse_ner_tags(vocab, words, biluo_or_offsets):
    if isinstance(biluo_or_offsets[0], (list, tuple)):
        # Convert to biluo if necessary
        # This is annoying but to convert the offsets we need a Doc
        # that has the target tokenization.
        reference = Doc(vocab, words=words)
        biluo = biluo_tags_from_offsets(reference, biluo_or_offsets)
    else:
        biluo = biluo_or_offsets
    ent_iobs = []
    ent_types = []
    for iob_tag in biluo_to_iob(biluo):
        ent_iobs.append(iob_tag.split("-")[0])
        if iob_tag.startswith("I") or iob_tag.startswith("B"):
            ent_types.append(iob_tag.split("-", 1)[1])
        else:
            ent_types.append("")
    return ent_iobs, ent_types

def _parse_links(vocab, words, links, entities):
    reference = Doc(vocab, words=words)

    starts = {token.idx: token.i for token in reference}
    ends = {token.idx + len(token): token.i for token in reference}
    ent_kb_ids = ["" for _ in reference]
    entity_map = [(ent[0], ent[1]) for ent in entities]

    # links annotations need to refer 1-1 to entity annotations - throw error otherwise
    for index, annot_dict in links.items():
        start_char, end_char = index
        if (start_char, end_char) not in entity_map:
            raise ValueError(Errors.E984)

    for index, annot_dict in links.items():
        true_kb_ids = []
        for key, value in annot_dict.items():
            if value == 1.0:
                true_kb_ids.append(key)
        if len(true_kb_ids) > 1:
            raise ValueError(Errors.E983)

        if len(true_kb_ids) == 1:
            start_char, end_char = index
            start_token = starts.get(start_char)
            end_token = ends.get(end_char)
            for i in range(start_token, end_token+1):
                ent_kb_ids[i] = true_kb_ids[0]

    return ent_kb_ids


class Example:
    def get_aligned(self, field):
        """Return an aligned array for a token annotation field."""
        if self.doc is None:
            return self.token_annotation.get_field(field)
        doc = self.doc
        if field == "word":
            return [token.orth_ for token in doc]
        gold_values = self.token_annotation.get_field(field)
        alignment = self.alignment
        i2j_multi = alignment.i2j_multi
        gold_to_cand = alignment.gold_to_cand
        cand_to_gold = alignment.cand_to_gold

        output = []
        for i, gold_i in enumerate(cand_to_gold):
            if doc[i].text.isspace():
                output.append(None)
            elif gold_i is None:
                if i in i2j_multi:
                    output.append(gold_values[i2j_multi[i]])
                else:
                    output.append(None)
            else:
                output.append(gold_values[gold_i])
        return output

    def split_sents(self):
        """ Split the token annotations into multiple Examples based on
        sent_starts and return a list of the new Examples"""
        if not self.token_annotation.words:
            return [self]
        s_ids, s_words, s_tags, s_pos, s_morphs = [], [], [], [], []
        s_lemmas, s_heads, s_deps, s_ents, s_sent_starts = [], [], [], [], []
        s_brackets = []
        sent_start_i = 0
        t = self.token_annotation
        split_examples = []
        for i in range(len(t.words)):
            if i > 0 and t.sent_starts[i] == 1:
                split_examples.append(
                    Example(
                        doc=Doc(self.doc.vocab, words=s_words),
                        token_annotation=TokenAnnotation(
                            ids=s_ids,
                            words=s_words,
                            tags=s_tags,
                            pos=s_pos,
                            morphs=s_morphs,
                            lemmas=s_lemmas,
                            heads=s_heads,
                            deps=s_deps,
                            entities=s_ents,
                            sent_starts=s_sent_starts,
                            brackets=s_brackets,
                        ),
                        doc_annotation=self.doc_annotation
                    )
                )
                s_ids, s_words, s_tags, s_pos, s_heads = [], [], [], [], []
                s_deps, s_ents, s_morphs, s_lemmas = [], [], [], []
                s_sent_starts, s_brackets = [], []
                sent_start_i = i
            s_ids.append(t.get_id(i))
            s_words.append(t.get_word(i))
            s_tags.append(t.get_tag(i))
            s_pos.append(t.get_pos(i))
            s_morphs.append(t.get_morph(i))
            s_lemmas.append(t.get_lemma(i))
            s_heads.append(t.get_head(i) - sent_start_i)
            s_deps.append(t.get_dep(i))
            s_ents.append(t.get_entity(i))
            s_sent_starts.append(t.get_sent_start(i))
            for b_end, b_label in t.brackets_by_start.get(i, []):
                s_brackets.append((i - sent_start_i, b_end - sent_start_i, b_label))
            i += 1
        split_examples.append(
            Example(
                doc=Doc(self.doc.vocab, words=s_words),
                token_annotation=TokenAnnotation(
                    ids=s_ids,
                    words=s_words,
                    tags=s_tags,
                    pos=s_pos,
                    morphs=s_morphs,
                    lemmas=s_lemmas,
                    heads=s_heads,
                    deps=s_deps,
                    entities=s_ents,
                    sent_starts=s_sent_starts,
                    brackets=s_brackets,
                ),
                doc_annotation=self.doc_annotation
            )
        )
        return split_examples

    @classmethod
    def to_example_objects(cls, examples, make_doc=None, keep_raw_text=False):
        """
        Return a list of Example objects, from a variety of input formats.
        make_doc needs to be provided when the examples contain text strings and keep_raw_text=False
        """
        if isinstance(examples, Example):
            return [examples]
        if isinstance(examples, tuple):
            examples = [examples]
        converted_examples = []
        for ex in examples:
            if isinstance(ex, Example):
                converted_examples.append(ex)
            # convert string to Doc to Example
            elif isinstance(ex, str):
                if keep_raw_text:
                    converted_examples.append(Example(doc=ex))
                else:
                    doc = make_doc(ex)
                    converted_examples.append(Example(doc=doc))
            # convert tuples to Example
            elif isinstance(ex, tuple) and len(ex) == 2:
                doc, gold = ex
                # convert string to Doc
                if isinstance(doc, str) and not keep_raw_text:
                    doc = make_doc(doc)
                converted_examples.append(Example.from_dict(gold, doc=doc))
            # convert Doc to Example
            elif isinstance(ex, Doc):
                converted_examples.append(Example(doc=ex))
            else:
                converted_examples.append(ex)
        return converted_examples

    def _deprecated_get_gold(self, make_projective=False):
        from ..syntax.gold_parse import get_parses_from_example

        _, gold = get_parses_from_example(self, make_projective=make_projective)[0]
        return gold


