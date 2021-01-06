#*****************************************************************************
#       Copyright (C) 2012 Volker Braun <vbraun.name@gmail.com>
#       Copyright (C) 2021 E. Madison Bray <embray@lri.fr>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#                  http://www.gnu.org/licenses/
#*****************************************************************************

from .gap_includes cimport Obj, UInt
#from sage.structure.element cimport Element, ModuleElement
cdef class Element:
    pass

cdef class ModuleElement:
    pass

cdef Obj make_gap_list(parent, lst) except NULL
cdef Obj make_gap_matrix(parent, lst, gap_ring) except NULL
cdef Obj make_gap_record(parent, dct) except NULL
cdef Obj make_gap_integer(x) except NULL
cdef Obj make_gap_float(x) except NULL
cdef Obj make_gap_string(s) except NULL

cdef GapObj make_any_gap_element(parent, Obj obj)
cdef GapObj make_GapObj(parent, Obj obj)
cdef GapList make_GapList(parent, Obj obj)
cdef GapRecord make_GapRecord(parent, Obj obj)
cdef GapInteger make_GapInteger(parent, Obj obj)
cdef GapFloat make_GapFloat(parent, Obj obj)
cdef GapRational make_GapRational(parent, Obj obj)
cdef GapString make_GapString(parent, Obj obj)
cdef GapBoolean make_GapBoolean(parent, Obj obj)
cdef GapFunction make_GapFunction(parent, Obj obj)
cdef GapPermutation make_GapPermutation(parent, Obj obj)

cdef char *capture_stdout(Obj, Obj)
cdef char *gap_element_str(Obj)
cdef char *gap_element_repr(Obj)


cdef class GapObj:
    # the instance of the Gap interpreter class; currently for compatibility
    # with Sage's Element class though not clear yet if it will make entire
    # sense to keep.
    cdef object _parent

    # the pointer to the GAP object (memory managed by GASMAN)
    cdef Obj value

    # comparison
    cdef bint _compare_by_id
    cdef bint _compare_equal(self, Element other) except -2
    cdef bint _compare_less(self, Element other) except -2
    cpdef _set_compare_by_id(self)
    cpdef _assert_compare_by_id(self)

    cdef _initialize(self, parent, Obj obj)
    cpdef _type_number(self)
    cpdef is_bool(self)
    cpdef _add_(self, other)
    cpdef _div_(self, other)
    cpdef _sub_(self, other)
    cpdef _mul_(self, other)
    cpdef _mod_(self, other)
    cpdef _pow_(self, other)
    cpdef _pow_int(self, other)
    cpdef _richcmp_(self, other, int op)

    cpdef GapObj deepcopy(self, bint mut)

cdef class GapInteger(GapObj):
    pass

cdef class GapFloat(GapObj):
    pass

cdef class GapRational(GapObj):
    pass

cdef class GapIntegerMod(GapObj):
    cpdef GapInteger lift(self)

cdef class GapFiniteField(GapObj):
    cpdef GapInteger lift(self)

cdef class GapCyclotomic(GapObj):
    pass

cdef class GapRing(GapObj):
    pass

cdef class GapString(GapObj):
    pass

cdef class GapBoolean(GapObj):
    pass

cdef class GapFunction(GapObj):
    pass

cdef class GapMethodProxy(GapFunction):
    cdef GapObj first_argument

cdef class GapRecord(GapObj):
    cpdef UInt record_name_to_index(self, name)

cdef class GapRecordIterator:
    cdef GapRecord rec
    cdef UInt i

cdef class GapList(GapObj):
    pass

cdef class GapPermutation(GapObj):
    pass
