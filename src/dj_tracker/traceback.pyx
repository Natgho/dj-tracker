cimport cython
from cpython.object cimport PyObject
from cpython.pystate cimport PyFrameObject

from functools import lru_cache
from linecache import getline

from django.template import Node

from dj_tracker.constants import IGNORED_MODULES
from dj_tracker.hash_utils import HashableList, hash_string
from dj_tracker.promise import SourceFilePromise


cdef extern from "Python.h":
    void Py_INCREF(PyObject*)
    void Py_DECREF(PyObject*)

    ctypedef struct PyCodeObject:
        PyObject *co_filename
        PyObject *co_name

    PyFrameObject *PyEval_GetFrame()
    int PyFrame_GetLineNumber(PyFrameObject*)


cdef extern from "pythoncapi_compat.h":
    PyFrameObject *PyFrame_GetBack(PyFrameObject*)
    PyCodeObject *PyFrame_GetCode(PyFrameObject*)
    PyObject *PyFrame_GetVar(PyFrameObject*, PyObject*)


@lru_cache(maxsize=None)
def ignore_file(filename: str) -> bool:
    """Indicates whether the frame containing the given filename should be ignored."""
    return any(module in filename for module in IGNORED_MODULES)


@lru_cache(maxsize=512)
def get_entry(*args) -> TracebackEntry:
    return TracebackEntry(*args)


@cython.freelist(512)
cdef class TracebackEntry:
    cdef:
        readonly str filename
        readonly int lineno
        readonly str func

        int hash_value
        bint ignore
        bint is_render

    def __init__(self, str filename, int lineno, str func=""):
        self.filename = filename
        self.lineno = lineno
        self.func = func
        self.ignore = ignore_file(filename)
        self.is_render = func == "render"

    @property
    def code(self):
        return getline(self.filename, self.lineno).strip()

    @property
    def filename_id(self):
        return SourceFilePromise.get_or_create(name=self.filename)

    @property
    def cache_key(self):
        return hash(
            (
                self.filename_id,
                self.lineno,
                hash_string(self.code),
                hash_string(self.func),
            )
        )
    
    def __getattr__(self, name):
        if name == "hash_value":
            self.hash_value = hash_value = hash((self.filename, self.lineno))
            return hash_value
        raise AttributeError

    def __repr__(self):
        return f"{self.filename} {self.code}"


cpdef get_traceback(get_entry=get_entry):
    cdef:
        PyFrameObject *frame, *last_frame
        PyCodeObject *code
        PyObject *node
        TracebackEntry entry
        str self_var = "self"
        bint top_entries_found = False
        int num_bottom_entries = 0
        list stack = <list>HashableList()
        object template_info = None

    if not (last_frame := PyEval_GetFrame()):
        return (), None

    Py_INCREF(<PyObject*>last_frame)

    while frame := PyFrame_GetBack(last_frame):
        Py_DECREF(<PyObject*>last_frame)
        last_frame = frame

        code = PyFrame_GetCode(frame)
        entry = get_entry(
            <object>code.co_filename,
            PyFrame_GetLineNumber(frame),
            <object>code.co_name,
        )
        Py_DECREF(<PyObject*>code)

        if template_info is None and entry.is_render:
            try:
                node = PyFrame_GetVar(frame, <PyObject*>self_var)
            except NameError:
                pass
            else:
                node_obj = <object>node
                if isinstance(node_obj, Node):
                    template_info = get_entry(node_obj.origin.name, node_obj.token.lineno)
                Py_DECREF(node)

        if entry.ignore:
            if top_entries_found:
                stack.append(entry)
                num_bottom_entries += 1
        else:
            if num_bottom_entries:
                num_bottom_entries = 0
            elif not top_entries_found:
                top_entries_found = True

            stack.append(entry)

    Py_DECREF(<PyObject*>last_frame)

    if num_bottom_entries:
        stack[-num_bottom_entries:] = []

    return stack, template_info
