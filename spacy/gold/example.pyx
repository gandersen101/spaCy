import warnings

import numpy

from ..tokens import Token
from ..tokens.doc cimport Doc
from ..tokens.span cimport Span
from ..tokens.span import Span
from ..attrs import IDS
from .align cimport Alignment
from .iob_utils import biluo_to_iob, biluo_tags_from_offsets, biluo_tags_from_doc
from .iob_utils import spans_from_biluo_tags
from .align import Alignment
from ..errors import Errors, AlignmentError
from ..syntax import nonproj
from ..util import get_words_and_spaces


cpdef Doc annotations2doc(vocab, tok_annot, doc_annot):
    """ Create a Doc from dictionaries with token and doc annotations. Assumes ORTH & SPACY are set. """
    attrs, array = _annot2array(vocab, tok_annot, doc_annot)
    output = Doc(vocab, words=tok_annot["ORTH"], spaces=tok_annot["SPACY"])
    if array.size:
        output = output.from_array(attrs, array)
    if "entities" in doc_annot:
       _add_entities_to_doc(output, doc_annot["entities"])
    # TODO: links ?!
    output.cats.update(doc_annot.get("cats", {}))
    return output


cdef class Example:
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
        example_dict = _fix_legacy_dict_data(example_dict)
        tok_dict, doc_dict = _parse_example_dict_data(example_dict)
        if "ORTH" not in tok_dict:
            tok_dict["ORTH"] = [tok.text for tok in predicted]
            tok_dict["SPACY"] = [tok.whitespace_ for tok in predicted]
        if not _has_field(tok_dict, "SPACY"):
            spaces = _guess_spaces(predicted.text, tok_dict["ORTH"])
        return Example(
            predicted,
            annotations2doc(predicted.vocab, tok_dict, doc_dict)
        )
    
    @property
    def alignment(self):
        if self._alignment is None:
            spacy_words = [token.orth_ for token in self.predicted]
            gold_words = [token.orth_ for token in self.reference]
            if gold_words == []:
                gold_words = spacy_words
            self._alignment = Alignment(spacy_words, gold_words)
        return self._alignment

    def get_aligned(self, field, as_string=False):
        """Return an aligned array for a token attribute."""
        alignment = self.alignment
        i2j_multi = alignment.i2j_multi
        j2i_multi = alignment.j2i_multi
        gold_to_cand = alignment.gold_to_cand
        cand_to_gold = alignment.cand_to_gold

        vocab = self.reference.vocab
        gold_values = self.reference.to_array([field])
        output = [None] * len(self.predicted)
        for i, gold_i in enumerate(cand_to_gold):
            if self.predicted[i].text.isspace():
                output[i] = None
            if gold_i is None:
                if i in i2j_multi:
                    output[i] = gold_values[i2j_multi[i]]
                else:
                    output[i] = None
            else:
                output[i] = gold_values[gold_i]
        if as_string and field not in ["ENT_IOB", "SENT_START"]:
            output = [vocab.strings[o] if o is not None else o for o in output]
        return output

    def get_aligned_parse(self, projectivize=True):
        cand_to_gold = self.alignment.cand_to_gold
        gold_to_cand = self.alignment.gold_to_cand
        aligned_heads = [None] * self.x.length
        aligned_deps = [None] * self.x.length
        heads = [token.head.i for token in self.y]
        deps = [token.dep_ for token in self.y]
        heads, deps = nonproj.projectivize(heads, deps)
        for cand_i in range(self.x.length):
            gold_i = cand_to_gold[cand_i]
            if gold_i is not None: # Alignment found
                gold_head = gold_to_cand[heads[gold_i]]
                if gold_head is not None:
                    aligned_heads[cand_i] = gold_head
                    aligned_deps[cand_i] = deps[gold_i]
        return aligned_heads, aligned_deps

    def get_aligned_ner(self):
        x_ents = []
        gold_to_cand = self.alignment.gold_to_cand
        x_text = self.x.text
        for y_ent in self.y.ents:
            x_start = gold_to_cand[y_ent.start]
            x_end = gold_to_cand[y_ent.end-1]
            if x_start is not None and x_end is not None:
                x_ents.append(Span(self.x, x_start, x_end+1, label=y_ent.label))
            elif x_text.count(y_ent.text) == 1:
                start_char = x_text.index(y_ent.text)
                end_char = start_char + len(y_ent.text)
                x_span = self.x.char_span(start_char, end_char, label=y_ent.label)
                if x_span is not None:
                    x_ents.append(x_span)
            else:
                print(y_ent, y_ent.label_)
        x_tags = biluo_tags_from_offsets(
            self.x, 
            [(e.start_char, e.end_char, e.label_) for e in x_ents],
            missing="O"
        )
        for token in self.y:
            if token.ent_iob == 0:
                cand_i = gold_to_cand[token.i]
                if cand_i is not None:
                    x_tags[cand_i] = None
        return x_tags

    def to_dict(self):
        return {
            "doc_annotation": {
                "cats": dict(self.reference.cats),
                "entities": biluo_tags_from_doc(self.reference),
                "links": self._links_to_dict()
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
                "sent_starts": [int(bool(t.is_sent_start)) for t in self.reference]
            }
        }

    def _links_to_dict(self):
        links = {}
        for ent in self.reference.ents:
            if ent.kb_id_:
                links[(ent.start_char, ent.end_char)] = {ent.kb_id_: 1.0}
        return links


    def split_sents(self):
        """ Split the token annotations into multiple Examples based on
        sent_starts and return a list of the new Examples"""
        if not self.reference.is_sentenced:
            return [self]

        sent_starts = self.get_aligned("SENT_START")
        sent_starts.append(1)   # appending virtual start of a next sentence to facilitate search

        output = []
        pred_start = 0
        for sent in self.reference.sents:
            new_ref = sent.as_doc()
            pred_end = sent_starts.index(1, pred_start+1)  # find where the next sentence starts
            new_pred = self.predicted[pred_start : pred_end].as_doc()
            output.append(Example(new_pred, new_ref))
            pred_start = pred_end

        return output

    property text:
        def __get__(self):
            return self.x.text

    def __str__(self):
        return str(self.to_dict())

    def __repr__(self):
        return str(self.to_dict())


def _annot2array(vocab, tok_annot, doc_annot):
    attrs = []
    values = []

    for key, value in doc_annot.items():
        if value:
            if key == "entities":
                pass
            elif key == "links":
                entities = doc_annot.get("entities", {})
                if value and not entities:
                    raise ValueError(Errors.E981)
                ent_kb_ids = _parse_links(vocab, tok_annot["ORTH"], value, entities)
                tok_annot["ENT_KB_ID"] = ent_kb_ids
            elif key == "cats":
                pass
            else:
                raise ValueError(f"Unknown doc attribute: {key}")

    for key, value in tok_annot.items():
        if key not in IDS:
            raise ValueError(f"Unknown token attribute: {key}")
        elif key in ["ORTH", "SPACY"]:
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
        else:
            attrs.append(key)
            values.append([vocab.strings.add(v) for v in value])

    array = numpy.asarray(values, dtype="uint64")
    return attrs, array.T


def _add_entities_to_doc(doc, ner_data):
    if ner_data is None:
        return
    elif ner_data == []:
        doc.ents = []
    elif isinstance(ner_data[0], tuple):
        return _add_entities_to_doc(
            doc,
            biluo_tags_from_offsets(doc, ner_data)
        )
    elif isinstance(ner_data[0], str) or ner_data[0] is None:
        return _add_entities_to_doc(
            doc,
            spans_from_biluo_tags(doc, ner_data)
        )
    elif isinstance(ner_data[0], Span):
        # Ugh, this is super messy. Really hard to set O entities
        doc.ents = ner_data
        doc.ents = [span for span in ner_data if span.label_]
    else:
        raise ValueError("Unexpected type for NER data")


def _parse_example_dict_data(example_dict):
    return (
        example_dict["token_annotation"],
        example_dict["doc_annotation"]
    )


def _fix_legacy_dict_data(example_dict):
    token_dict = example_dict.get("token_annotation", {})
    doc_dict = example_dict.get("doc_annotation", {})
    for key, value in example_dict.items():
        if value:
            if key in ("token_annotation", "doc_annotation"):
                pass
            elif key == "ids":
                pass
            elif key in ("cats", "links"):
                doc_dict[key] = value
            elif key in ("ner", "entities"):
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
        "spaces": "SPACY",
    }
    old_token_dict = token_dict
    token_dict = {}
    for key, value in old_token_dict.items():
        if key in ("text", "ids", "brackets"):
            pass
        elif key in remapping:
            token_dict[remapping[key]] = value
        else:
            raise KeyError(Errors.E983.format(key=key, dict="token_annotation", keys=remapping.keys()))
    text = example_dict.get("text", example_dict.get("raw"))
    if text and not _has_field(token_dict, "SPACY"):
        token_dict["SPACY"] = _guess_spaces(text, token_dict["ORTH"])
    if "HEAD" in token_dict and "SENT_START" in token_dict:
        # If heads are set, we don't also redundantly specify SENT_START.
        token_dict.pop("SENT_START")
        warnings.warn("Ignoring annotations for sentence starts, as dependency heads are set")
    return {
        "token_annotation": token_dict,
        "doc_annotation": doc_dict
    }

def _has_field(annot, field):
    if field not in annot:
        return False
    elif annot[field] is None:
        return False
    elif len(annot[field]) == 0:
        return False
    elif all([value is None for value in annot[field]]):
        return False
    else:
        return True


def _parse_ner_tags(biluo_or_offsets, vocab, words, spaces):
    if isinstance(biluo_or_offsets[0], (list, tuple)):
        # Convert to biluo if necessary
        # This is annoying but to convert the offsets we need a Doc
        # that has the target tokenization.
        reference = Doc(vocab, words=words, spaces=spaces)
        biluo = biluo_tags_from_offsets(reference, biluo_or_offsets)
    else:
        biluo = biluo_or_offsets
    ent_iobs = []
    ent_types = []
    for iob_tag in biluo_to_iob(biluo):
        if iob_tag in (None, "-"):
            ent_iobs.append("")
            ent_types.append("")
        else:
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
            raise ValueError(Errors.E981)

    for index, annot_dict in links.items():
        true_kb_ids = []
        for key, value in annot_dict.items():
            if value == 1.0:
                true_kb_ids.append(key)
        if len(true_kb_ids) > 1:
            raise ValueError(Errors.E980)

        if len(true_kb_ids) == 1:
            start_char, end_char = index
            start_token = starts.get(start_char)
            end_token = ends.get(end_char)
            for i in range(start_token, end_token+1):
                ent_kb_ids[i] = true_kb_ids[0]

    return ent_kb_ids


def _guess_spaces(text, words):
    spaces = []
    text_pos = 0
    # align words with text
    for word in words:
        try:
            word_start = text[text_pos:].index(word)
        except ValueError:
            spaces.append(True)
            continue
        text_pos += word_start + len(word)
        if text_pos < len(text) and text[text_pos] == " ":
            spaces.append(True)
        else:
            spaces.append(False)
    return spaces
