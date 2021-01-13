"""
GAP object wrappers.

This document describes the individual wrappers for various GAP objects.
"""

# ****************************************************************************
#       Copyright (C) 2012 Volker Braun <vbraun.name@gmail.com>
#       Copyright (C) 2021 E. Madison Bray <embray@lri.fr>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#                  https://www.gnu.org/licenses/
# ****************************************************************************

import itertools
from textwrap import dedent

from cpython.longintrepr cimport py_long, digit, PyLong_SHIFT, _PyLong_New
from cpython.object cimport Py_EQ, Py_NE, Py_LE, Py_GE, Py_LT, Py_GT, Py_SIZE
from cysignals.signals cimport sig_on, sig_off

from .gap_includes cimport *
from .gmp cimport *
from .core cimport *
from .exceptions import GAPError
from .operations import OperationInspector


#from sage.cpython.string cimport str_to_bytes, char_to_str
cdef str_to_bytes(str s, str encoding='utf-8', str errors='strict'):
    return s.encode(encoding, errors)
cdef char_to_str(char *s):
    return s.decode('utf-8')


decode_type_number = {
    0: 'T_INT (integer)',
    T_INTPOS: 'T_INTPOS (positive integer)',
    T_INTNEG: 'T_INTNEG (negative integer)',
    T_RAT: 'T_RAT (rational number)',
    T_CYC: 'T_CYC (universal cyclotomic)',
    T_FFE: 'T_FFE (finite field element)',
    T_PERM2: 'T_PERM2',
    T_PERM4: 'T_PERM4',
    T_BOOL: 'T_BOOL',
    T_CHAR: 'T_CHAR',
    T_FUNCTION: 'T_FUNCTION',
    T_PLIST: 'T_PLIST',
    T_PLIST_CYC: 'T_PLIST_CYC',
    T_BLIST: 'T_BLIST',
    T_STRING: 'T_STRING',
    T_MACFLOAT: 'T_MACFLOAT (hardware floating point number)',
    T_COMOBJ: 'T_COMOBJ (component object)',
    T_POSOBJ: 'T_POSOBJ (positional object)',
    T_DATOBJ: 'T_DATOBJ (data object)',
    T_WPOBJ:  'T_WPOBJ (weak pointer object)',
    }

############################################################################
### helper functions to construct lists and records ########################
############################################################################

cdef Obj make_gap_list(parent, lst) except NULL:
    """
    Convert Sage lists into GAP lists

    INPUT:

    - ``a`` -- list of :class:`GapObj`.

    OUTPUT:

    The list of the elements in ``a`` as a GAP ``Obj``.
    """
    cdef Obj l
    cdef GapObj elem
    try:
        GAP_Enter()
        l = GAP_NewPlist(len(lst))
        for idx, x in enumerate(lst):
            if not isinstance(x, GapObj):
                elem = <GapObj>parent(x)
            else:
                elem = <GapObj>x

            GAP_AssList(l, idx + 1, elem.value)
        return l
    finally:
        GAP_Leave()


cdef Obj make_gap_matrix(parent, lst, gap_ring) except NULL:
    """
    Convert Python lists into GAP matrices.

    .. todo::

        Perhaps support Numpy arrays as well.

    INPUT:

    - ``lst`` -- list of :class:`GapObj` or objects that can converted to one

    - ``gap_ring`` -- the base ring

    If ``gap_ring`` is ``None``, nothing is made to make sure
    that all coefficients live in the same GAP ring. The resulting GAP list
    may not be recognized as a matrix by GAP.

    OUTPUT:

    The list of the elements in ``lst`` as a GAP ``Obj``.
    """
    cdef GapObj l = parent.eval('[]')
    cdef GapObj elem
    cdef GapObj one
    if gap_ring is not None:
        one = <GapObj>gap_ring.One()
    else:
        one = <GapObj>parent(1)
    for x in lst:
        if not isinstance(x, GapObj):
            elem = <GapObj>parent(x)
            elem = elem * one
        else:
            elem = <GapObj>x

        GAP_AssList(l.value, GAP_LenList(l.value) + 1, elem.value)
    return l.value


cdef void capture_stdout(Obj func, Obj obj, Obj out):
    """
    Call a single-argument GAP function ``func`` with the argument ``obj``
    and return the stdout from that function call to the GAP string ``out``.

    This can be used to capture the output of GAP functions that are used to
    print objects such as ``Print()`` and ``ViewObj()``.
    """
    cdef Obj stream, output_text_string
    cdef UInt res
    cdef Obj args[2]
    # The only way to get a string representation of an object that is truly
    # consistent with how it would be represented at the GAP REPL is to call
    # ViewObj on it.  Unfortunately, ViewObj *prints* to the output stream,
    # and there is no equivalent that simply returns the string that would be
    # printed.  The closest approximation would be DisplayString, but this
    # bypasses any type-specific overrides for ViewObj so for many objects
    # that does not give consistent results.
    # TODO: This is probably needlessly slow, but we might need better
    # support from GAP to improve this...
    try:
        GAP_Enter()
        output_text_string = GAP_ValueGlobalVariable("OutputTextString")
        args[0] = out
        args[1] = GAP_True
        stream = GAP_CallFuncArray(output_text_string, 2, args)

        if not OpenOutputStream(stream):
            raise GAPError("failed to open output capture stream for "
                           "representing GAP object")

        args[0] = obj
        GAP_CallFuncArray(func, 1, args)
        CloseOutput()
    finally:
        GAP_Leave()


cdef void gap_obj_repr(Obj obj, Obj out):
    """
    Implement ``repr()`` of ``GapObj``s using the ``ViewObj()`` function,
    which is by default closest to what you get when displaying an object in
    GAP on the command-line (i.e. when evaluating an expression that returns
    that object.
    """

    cdef Obj func = GAP_ValueGlobalVariable("ViewObj")
    capture_stdout(func, obj, out)


cdef void gap_obj_str(Obj obj, Obj out):
    """
    Implement ``str()`` of ``GapObj``s using the ``Print()`` function.

    This mirrors somewhat how Python uses ``str()`` on an object when passing
    it to the ``print()`` function.  This is also how the GAP pexpect interface
    has traditionally repr'd objects; for the libgap interface we take a
    slightly different approach more closely mirroring Python's str/repr
    difference (though this does not map perfectly onto GAP).
    """
    cdef Obj func = GAP_ValueGlobalVariable("Print")
    capture_stdout(func, obj, out)


cdef Obj make_gap_record(parent, dct) except NULL:
    """
    Convert Python dicts into GAP records.

    INPUT:

    - ``a`` -- a dict mapping stringifiable keys to values of :class:`GapObj`
      or that can be converted to one

    OUTPUT:

    A `GapRecord` instance.

    TESTS::

        >>> gap({'a': 1, 'b':123})  # indirect doctest
        rec( a := 1, b := 123 )
    """

    cdef Obj rec, name
    cdef GapObj val

    try:
        GAP_Enter()
        rec = GAP_NewPrecord(len(dct))
        for key, val in dct.items():
            name = make_gap_string(str(key))
            val = parent(val)
            GAP_AssRecord(rec, name, val.value)
        return rec
    finally:
        GAP_Leave()


cdef Obj make_gap_integer(x) except NULL:
    """
    Convert a Python int to a GAP integer

    INPUT:

    - ``x`` -- a Python integer.

    OUTPUT:

    The integer as a GAP ``Obj``.

    TESTS::

        >>> gap(1)   # indirect doctest
        1
    """

    cdef Obj result
    cdef mpz_t z
    cdef UInt s
    cdef UInt *limbs
    cdef Int size = Py_SIZE(x)
    cdef Int sign = (size > 0) - (size < 0)
    cdef Int do_clear = 0

    if -1 <= size <= 1:
        # Shortcut for smaller ints (up to 30 bits)
        s = <UInt>((<py_long>x).ob_digit[0])
        limbs = &s
    else:
        # See https://github.com/gap-system/gap/issues/4209
        mpz_init(z)
        mpz_import(z, size * sign, -1, sizeof(digit), 0,
                   (sizeof(digit) * 8) - PyLong_SHIFT, (<py_long>x).ob_digit)
        do_clear = 1
        if sign < 0:
            mpz_neg(z, z)
        limbs = <UInt *>mpz_limbs_read(z)
        size = <Int>mpz_size(z) * sign

    try:
        GAP_Enter()
        result = GAP_MakeObjInt(limbs, size)
        return result
    finally:
        GAP_Leave()
        if do_clear:
            mpz_clear(z)


cdef Obj make_gap_float(x) except NULL:
    """
    Convert a Python float to a GAP machine float

    INPUT:

    - ``x`` -- a Python float.

    OUTPUT:

    The float as a GAP ``Obj``.

    TESTS::

        >>> gap(1.23)  # indirect doctest
        1.23
    """
    cdef Obj result
    try:
        GAP_Enter()
        result = GAP_NewMacFloat(<double>x)
        return result
    finally:
        GAP_Leave()


cdef Obj make_gap_string(s) except NULL:
    """
    Convert a Python string to a GAP string

    INPUT:

    - ``s`` -- a Python str.

    OUTPUT:

    The string as a GAP ``Obj``.

    TESTS::

        >>> gap('string')  # indirect doctest
        "string"
    """
    try:
        GAP_Enter()
        b = str_to_bytes(s)
        return GAP_MakeStringWithLen(b, len(b))
    finally:
        GAP_Leave()


############################################################################
### generic construction of GapObjs ########################################
############################################################################

cdef GapObj make_any_gap_obj(parent, Obj obj):
    """
    Return the GapObj wrapper of ``obj``

    The most suitable subclass of GapObj is determined
    automatically. Use this function to wrap GAP objects unless you
    know exactly which type it is (then you can use the specialized
    ``make_GapElement_...``)

    TESTS::

        >>> T_CHAR = gap.eval("'c'");  T_CHAR
        "c"
        >>> type(T_CHAR)
        <class 'gappy.gapobj.GapString'>

        >>> gap.eval("['a', 'b', 'c']")   # gap strings are also lists of chars
        "abc"
        >>> t = gap.UnorderedTuples('abc', 2);  t
        [ "aa", "ab", "ac", "bb", "bc", "cc" ]
        >>> t[1]
        "ab"
        >>> str(t[1])
        'ab'
        >>> list(t)
        ['aa', 'ab', 'ac', 'bb', 'bc', 'cc']

    Check that :trac:`18158` is fixed::

        >>> S = SymmetricGroup(5)
        >>> irr = gap.Irr(S)[3]
        >>> irr[0]
        6
        >>> irr[1]
        0
    """
    cdef int num

    try:
        GAP_Enter()
        if obj is NULL:
            return make_GapObj(parent, obj)
        num = TNUM_OBJ(obj)
        if GAP_IsInt(obj):
            return make_GapInteger(parent, obj)
        elif num == T_MACFLOAT:
            return make_GapFloat(parent, obj)
        elif num == T_CYC:
            return make_GapCyclotomic(parent, obj)
        elif num == T_FFE:
            return make_GapFiniteField(parent, obj)
        elif num == T_RAT:
            return make_GapRational(parent, obj)
        elif num == T_BOOL:
            return make_GapBoolean(parent, obj)
        elif num == T_FUNCTION:
            return make_GapFunction(parent, obj)
        elif num == T_PERM2 or num == T_PERM4:
            return make_GapPermutation(parent, obj)
        elif GAP_IsRecord(obj):
            return make_GapRecord(parent, obj)
        elif GAP_IsString(obj):
            return make_GapString(parent, obj)
        elif GAP_IsList(obj):
            return make_GapList(parent, obj)
        elif num == T_CHAR:
            ch = make_GapObj(parent, obj).IntChar().sage()
            return make_GapString(parent, make_gap_string(chr(ch)))
        result = make_GapObj(parent, obj)
        if num == T_POSOBJ:
            if result.IsZmodnZObj():
                return make_GapIntegerMod(parent, obj)
        if num == T_COMOBJ:
            if result.IsRing():
                return make_GapRing(parent, obj)
        return result
    finally:
        GAP_Leave()


############################################################################
### GapObj #################################################################
############################################################################

cdef GapObj make_GapObj(parent, Obj obj):
    r"""
    Turn a GAP C object (of type ``Obj``) into a Cython ``GapObj``.

    INPUT:

    - ``parent`` -- the parent of the new :class:`GapObj`

    - ``obj`` -- a GAP object.

    OUTPUT:

    A :class:`GapFunction` instance, or one of its derived
    classes if it is a better fit for the GAP object.

    EXAMPLES::

        >>> gap(0)
        0
        >>> type(_)
        <class 'gappy.gapobj.GapInteger'>

        >>> gap.eval('')
        >>> gap(None)
        Traceback (most recent call last):
        ...
        AttributeError: 'NoneType' object has no attribute '_libgap_init_'
    """
    cdef GapObj r = GapObj.__new__(GapObj)
    r._initialize(parent, obj)
    return r


cdef class GapObj:
    r"""
    Wrapper for all GAP objects.

    .. NOTE::

        In order to create ``GapObjs`` you should use the ``gap`` instance (the
        parent of all GAP elements) to convert things into ``GapObj``. You must
        not create ``GapObj`` instances manually.

    EXAMPLES::

        >>> gap(0)
        0

    If GAP finds an error while evaluating, a :class:`GAPError`
    exception is raised::

        >>> gap.eval('1/0')
        Traceback (most recent call last):
        ...
        gappy.exceptions.GAPError: Error, Rational operations: <divisor> must
        not be zero

    Also, a ``GAPError`` is raised if the input is not a simple expression::

        >>> gap.eval('1; 2; 3')
        Traceback (most recent call last):
        ...
        gappy.exceptions.GAPError: can only evaluate a single statement
    """

    def __cinit__(self):
        """
        The Cython constructor.

        EXAMPLES::

            >>> gap.eval('1')
            1
        """
        self.value = NULL
        self._compare_by_id = False

    def __init__(self):
        """
        The ``GapObj`` constructor

        Users must use the ``gap`` instance to construct instances of
        :class:`GapObj`. Cython programmers must use :func:`make_GapObj`
        factory function.

        TESTS::

            >>> from gappy.gapobj import GapObj
            >>> GapObj()
            Traceback (most recent call last):
            ...
            TypeError: this class cannot be instantiated from Python
        """
        raise TypeError('this class cannot be instantiated from Python')

    cdef _initialize(self, parent, Obj obj):
        r"""
        Initialize the GapObj.

        This Cython method is called from :func:`make_GapObj` to
        initialize the newly-constructed object. You must never call
        it manually.

        TESTS::

            >>> n_before = gap.count_GAP_objects()
            >>> a = gap.eval('123')
            >>> b = gap.eval('456')
            >>> c = gap.eval('CyclicGroup(3)')
            >>> d = gap.eval('"a string"')
            >>> gap.collect()
            >>> del c
            >>> gap.collect()
            >>> n_after = gap.count_GAP_objects()
            >>> n_after - n_before
            3
        """
        assert self.value is NULL
        self._parent = parent
        self.value = obj
        if obj is NULL:
            return
        reference_obj(obj)

    def __dealloc__(self):
        r"""
        The Cython destructor

        TESTS::

            >>> pre_refcount = gap.count_GAP_objects()
            >>> def f():
            ...     local_variable = gap.eval('"This is a new string"')
            >>> f()
            >>> f()
            >>> f()
            >>> post_refcount = gap.count_GAP_objects()
            >>> post_refcount - pre_refcount
            0
        """
        if self.value is NULL:
            return
        dereference_obj(self.value)

    def __copy__(self):
        r"""
        TESTS::

            >>> a = gap(1)
            >>> a.__copy__() is a
            True

            >>> a = gap(1/3)
            >>> a.__copy__() is a
            True

            >>> a = gap([1,2])
            >>> b = a.__copy__()
            >>> a is b
            False
            >>> a[0] = 3
            >>> a
            [ 3, 2 ]
            >>> b
            [ 1, 2 ]

            >>> a = gap([[0,1],[2,3,4]])
            >>> b = a.__copy__()
            >>> b[0][1] = -2
            >>> b
            [ [ 0, -2 ], [ 2, 3, 4 ] ]
            >>> a
            [ [ 0, -2 ], [ 2, 3, 4 ] ]
        """
        if IS_MUTABLE_OBJ(self.value):
            return make_any_gap_obj(self.parent(), SHALLOW_COPY_OBJ(self.value))
        else:
            return self

    def parent(self, x=None):
        """
        For backwards-compatibility with Sage, returns either the
        `~gappy.core.Gap` interpreter instance associated with this `GapObj`,
        or the result of coercing ``x`` to a `GapObj`.
        """

        if x is None:
            return self._parent
        else:
            return self._parent(x)

    cpdef GapObj deepcopy(self, bint mut):
        r"""
        Return a deepcopy of this GAP object

        Note that this is the same thing as calling ``StructuralCopy`` but much
        faster.

        INPUT:

        - ``mut`` - (boolean) wheter to return an mutable copy

        EXAMPLES::

            >>> a = gap([[0,1],[2,3]])
            >>> b = a.deepcopy(1)
            >>> b[0,0] = 5
            >>> a
            [ [ 0, 1 ], [ 2, 3 ] ]
            >>> b
            [ [ 5, 1 ], [ 2, 3 ] ]

            >>> l = gap([0,1])
            >>> l.deepcopy(0).IsMutable()
            false
            >>> l.deepcopy(1).IsMutable()
            true
        """
        if IS_MUTABLE_OBJ(self.value):
            return make_any_gap_obj(self.parent(), CopyObj(self.value, mut))
        else:
            return self

    def __deepcopy__(self, memo):
        r"""
        TESTS::

            >>> from copy import deepcopy
            >>> a = gap([[0,1],[2]])
            >>> b = deepcopy(a)
            >>> a[0,0] = -1
            >>> a
            [ [ -1, 1 ], [ 2 ] ]
            >>> b
            [ [ 0, 1 ], [ 2 ] ]
        """
        return self.deepcopy(0)

    def __contains__(self, other):
        r"""
        TESTS::

            >>> gap(1) in gap.eval('Integers')
            True
            >>> 1 in gap.eval('Integers')
            True

            >>> 3 in gap([1,5,3,2])
            True
            >>> -5 in gap([1,5,3,2])
            False

            >>> gap.eval('Integers') in gap(1)
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found! Error, no 1st
            choice method found for `in' on 2 arguments
        """
        GAP_IN = self.parent().eval(r'\in')
        return bool(GAP_IN(other, self))

    cpdef _type_number(self):
        """
        Return the GAP internal type number.

        This is only useful for libgap development purposes.

        OUTPUT:

        Integer.

        EXAMPLES::

            >>> x = gap(1)
            >>> x._type_number()
            (0, 'T_INT (integer)')
        """
        n = TNUM_OBJ(self.value)
        global decode_type_number
        name = decode_type_number.get(n, 'unknown')
        return (n, name)

    def __dir__(self):
        """
        Customize tab completion

        EXAMPLES::

            >>> G = gap.DihedralGroup(4)
            >>> 'GeneratorsOfMagmaWithInverses' in dir(G)
            True
            >>> 'GeneratorsOfGroup' in dir(G)    # known bug
            False
            >>> x = gap(1)
            >>> len(dir(x)) > 100
            True
        """
        ops = OperationInspector(self).op_names()
        return dir(self.__class__) + ops

    def __getattr__(self, name):
        r"""
        Return functionoid implementing the function ``name``.

        EXAMPLES::

            >>> lst = gap([])
            >>> 'Add' in dir(lst)    # This is why tab-completion works
            True
            >>> lst.Add(1)    # this is the syntactic sugar
            >>> lst
            [ 1 ]

        The above is equivalent to the following calls::

            >>> lst = gap.eval('[]')
            >>> gap.eval('Add') (lst, 1)
            >>> lst
            [ 1 ]

        TESTS::

            >>> lst.Adddddd(1)
            Traceback (most recent call last):
            ...
            AttributeError: 'Adddddd' is not defined in GAP

            >>> gap.eval('some_name := 1')
            1
            >>> lst.some_name
            Traceback (most recent call last):
            ...
            AttributeError: 'some_name' does not define a GAP function
        """
        if name in ('__dict__', '_getAttributeNames', '__custom_name', 'keys'):
            raise AttributeError('Python special name, not a GAP function.')
        try:
            proxy = make_GapMethodProxy(self.parent(), gap_eval(name), self)
        except GAPError:
            raise AttributeError(f"'{name}' is not defined in GAP")
        if not proxy.is_function():
            raise AttributeError(f"'{name}' does not define a GAP function")
        return proxy

    def __str__(self):
        r"""
        Return a string representation of ``self`` for printing.

        EXAMPLES::

            >>> gap(0)
            0
            >>> print(gap.eval(''))
            None
            >>> print(gap('a'))
            a
            >>> print(gap.eval('SymmetricGroup(3)'))
            SymmetricGroup( [ 1 .. 3 ] )
            >>> gap(0).__str__()
            '0'
        """
        cdef Obj out

        if self.value == NULL:
            return 'NULL'

        try:
            GAP_Enter()
            out = GAP_MakeString("")
            gap_obj_str(self.value, out)
            s = char_to_str(GAP_CSTR_STRING(out))
            return s.strip()
        finally:
            GAP_Leave()

    def __repr__(self):
        r"""
        Return a string representation of ``self``.

        EXAMPLES::

            >>> gap(0)
            0
            >>> gap.eval('')
            >>> gap('a')
            "a"
            >>> gap.eval('SymmetricGroup(3)')
            Sym( [ 1 .. 3 ] )
            >>> gap(0).__repr__()
            '0'
        """
        cdef Obj out

        if self.value == NULL:
            return 'NULL'

        try:
            GAP_Enter()
            out = GAP_MakeString("")
            gap_obj_repr(self.value, out)
            s = char_to_str(GAP_CSTR_STRING(out))
            return s.strip()
        finally:
            GAP_Leave()

    cpdef _set_compare_by_id(self):
        """
        Set comparison to compare by ``id``

        By default, GAP is used to compare GAP objects. However,
        this is not defined for all GAP objects. To have GAP play
        nice with ``UniqueRepresentation``, comparison must always
        work. This method allows one to override the comparison to
        sort by the (unique) Python ``id``.

        Obviously it is a bad idea to change the comparison of objects
        after you have inserted them into a set/dict. You also must
        not mix GAP objects with different sort methods in the same
        container.

        EXAMPLES::

            >>> F1 = gap.FreeGroup(['a'])
            >>> F2 = gap.FreeGroup(['a'])
            >>> F1 < F2
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found!
            Error, no 1st choice method found for `<' on 2 arguments

            >>> F1._set_compare_by_id()
            >>> F1 != F2
            Traceback (most recent call last):
            ...
            ValueError: comparison style must be the same for both operands

            >>> F1._set_compare_by_id()
            >>> F2._set_compare_by_id()
            >>> F1 != F2
            True
        """
        self._compare_by_id = True

    cpdef _assert_compare_by_id(self):
        """
        Ensure that comparison is by ``id``

        See :meth:`_set_compare_by_id`.

        OUTPUT:

        This method returns nothing. A ``ValueError`` is raised if
        :meth:`_set_compare_by_id` has not been called on this libgap
        object.

        EXAMPLES::

            >>> x = gap.FreeGroup(1)
            >>> x._assert_compare_by_id()
            Traceback (most recent call last):
            ...
            ValueError: this requires a GAP object whose comparison is by "id"

            >>> x._set_compare_by_id()
            >>> x._assert_compare_by_id()
        """
        if not self._compare_by_id:
            raise ValueError('this requires a GAP object whose comparison is by "id"')

    def __hash__(self):
        """
        Make hashable.

        EXAMPLES::

            >>> hash(gap(123))  # doctest: +IGNORE_OUTPUT
            163512108404620371
        """
        return hash(str(self))

    def __richcmp__(self, other, int op):
        return self._richcmp_(self.parent(other), op)

    cpdef _richcmp_(self, other, int op):
        """
        Compare ``self`` with ``other``.

        Uses the GAP comparison by default, or the Python ``id`` if
        :meth:`_set_compare_by_id` was called.

        OUTPUT:

        Boolean, depending on the comparison of ``self`` and
        ``other``.  Raises a ``ValueError`` if GAP does not support
        comparison of ``self`` and ``other``, unless
        :meth:`_set_compare_by_id` was called on both ``self`` and
        ``other``.

        EXAMPLES::

            >>> a = gap(123)
            >>> a == a
            True
            >>> b = gap('string')
            >>> a._richcmp_(b, 0)
            1
            >>> (a < b) or (a > b)
            True
            >>> a._richcmp_(gap(123), 2)
            True

        GAP does not have a comparison function for two ``FreeGroup``
        objects. LibGAP signals this by raising a ``ValueError`` ::

            >>> F1 = gap.FreeGroup(['a'])
            >>> F2 = gap.FreeGroup(['a'])
            >>> F1 < F2
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found!
            Error, no 1st choice method found for `<' on 2 arguments

            >>> F1._set_compare_by_id()
            >>> F1 < F2
            Traceback (most recent call last):
            ...
            ValueError: comparison style must be the same for both operands

            >>> F1._set_compare_by_id()
            >>> F2._set_compare_by_id()
            >>> F1 < F2 or F1 > F2
            True

        Check that :trac:`26388` is fixed::

            >>> 1 > gap(1)
            False
            >>> gap(1) > 1
            False
            >>> 1 >= gap(1)
            True
            >>> gap(1) >= 1
            True
        """
        if self._compare_by_id != (<GapObj>other)._compare_by_id:
            raise ValueError("comparison style must be the same for both operands")
        if op == Py_LT:
            return self._compare_less(other)
        elif op == Py_LE:
            return self._compare_equal(other) or self._compare_less(other)
        elif op == Py_EQ:
            return self._compare_equal(other)
        elif op == Py_GT:
            return not self._compare_less(other) and not self._compare_equal(other)
        elif op == Py_GE:
            return not self._compare_less(other)
        elif op == Py_NE:
            return not self._compare_equal(other)
        else:
            assert False  # unreachable

    cdef bint _compare_equal(self, GapObj other) except -2:
        """
        Compare ``self`` with ``other``.

        Helper for :meth:`_richcmp_`

        EXAMPLES::

            >>> gap(1) == gap(1)   # indirect doctest
            True
        """
        if self._compare_by_id:
            return id(self) == id(other)

        sig_on()
        try:
            GAP_Enter()
            return EQ(self.value, other.value)
        finally:
            GAP_Leave()
            sig_off()

    cdef bint _compare_less(self, GapObj other) except -2:
        """
        Compare ``self`` with ``other``.

        Helper for :meth:`_richcmp_`

        EXAMPLES::

            >>> gap(1) < gap(2)   # indirect doctest
            True
        """
        if self._compare_by_id:
            return id(self) < id(other)

        sig_on()
        try:
            GAP_Enter()
            return LT(self.value, other.value)
        finally:
            GAP_Leave()
            sig_off()

    def __add__(left, right):
        # One or the other must be true.
        if isinstance(left, GapObj):
            return left._add_(left.parent(right))
        else:
            return right.parent(left)._add_(right)

    cpdef _add_(self, right):
        r"""
        Add two GapObj objects.

        EXAMPLES::

            >>> g1 = gap(1)
            >>> g2 = gap(2)
            >>> g1._add_(g2)
            3
            >>> g1 + g2    # indirect doctest
            3

            >>> gap(1) + gap.CyclicGroup(2)
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found!
            Error, no 1st choice method found for `+' on 2 arguments
        """
        cdef Obj result
        try:
            sig_GAP_Enter()
            sig_on()
            result = SUM(self.value, (<GapObj>right).value)
            sig_off()
        finally:
            GAP_Leave()
        return make_any_gap_obj(self.parent(), result)

    def __sub__(left, right):
        if isinstance(left, GapObj):
            return left._sub_(left.parent(right))
        else:
            return right.parent(left)._sub_(right)

    cpdef _sub_(self, right):
        r"""
        Subtract two GapObj objects.

        EXAMPLES::

            >>> g1 = gap(1)
            >>> g2 = gap(2)
            >>> g1._sub_(g2)
            -1
            >>> g1 - g2  # indirect doctest
            -1

            >>> gap(1) - gap.CyclicGroup(2)
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found! ...
        """
        cdef Obj result
        try:
            sig_GAP_Enter()
            sig_on()
            result = DIFF(self.value, (<GapObj>right).value)
            sig_off()
        finally:
            GAP_Leave()
        return make_any_gap_obj(self.parent(), result)

    def __mul__(left, right):
        if isinstance(left, GapObj):
            return left._mul_(left.parent(right))
        else:
            return right.parent(left)._mul_(right)

    cpdef _mul_(self, right):
        r"""
        Multiply two GapObj objects.

        EXAMPLES::

            >>> g1 = gap(3)
            >>> g2 = gap(5)
            >>> g1._mul_(g2)
            15
            >>> g1 * g2    # indirect doctest
            15

            >>> gap(1) * gap.CyclicGroup(2)
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found!
            Error, no 1st choice method found for `*' on 2 arguments
        """
        cdef Obj result
        try:
            sig_GAP_Enter()
            sig_on()
            result = PROD(self.value, (<GapObj>right).value)
            sig_off()
        finally:
            GAP_Leave()
        return make_any_gap_obj(self.parent(), result)

    def __truediv__(left, right):
        if isinstance(left, GapObj):
            return left._div_(left.parent(right))
        else:
            return right.parent(left)._div_(right)

    cpdef _div_(self, right):
        r"""
        Divide two GapObj objects.

        EXAMPLES::

            >>> g1 = gap(3)
            >>> g2 = gap(5)
            >>> g1._div_(g2)
            3/5
            >>> g1 / g2    # indirect doctest
            3/5

            >>> gap(1) / gap.CyclicGroup(2)
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found!
            Error, no 1st choice method found for `/' on 2 arguments

            >>> gap(1) / gap(0)
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, Rational operations: <divisor>
            must not be zero
        """
        cdef Obj result
        try:
            sig_GAP_Enter()
            sig_on()
            result = QUO(self.value, (<GapObj>right).value)
            sig_off()
        finally:
            GAP_Leave()
        return make_any_gap_obj(self.parent(), result)

    def __mod__(left, right):
        if isinstance(left, GapObj):
            return left._mod_(left.parent(right))
        else:
            return right.parent(left)._mod_(right)

    cpdef _mod_(self, right):
        r"""
        Modulus of two GapObj objects.

        EXAMPLES::

            >>> g1 = gap(5)
            >>> g2 = gap(2)
            >>> g1 % g2
            1

            >>> gap(1) % gap.CyclicGroup(2)
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found!
            Error, no 1st choice method found for `mod' on 2 arguments
        """
        cdef Obj result
        try:
            sig_GAP_Enter()
            sig_on()
            result = MOD(self.value, (<GapObj>right).value)
            sig_off()
        finally:
            GAP_Leave()
        return make_any_gap_obj(self.parent(), result)

    def __pow__(left, right, mod):
        if mod is not None:
            raise NotImplementedError(
                'pow with modulus not supported yet')

        # TODO: Support pow() with the mod; GAP must have a function for that
        if isinstance(left, GapObj):
            return left._pow_(left.parent(right))
        else:
            return right.parent(left)._pow_(right)

    def __xor__(left, right):
        """
        Exponentiation of a GapObj by the given power.

        In GAP the ``^`` operator is used for exponentiation as opposed to
        Python's ``**``, so for compatibility/familiarity, `GapObj` also
        supports exponentiation with ``^`` which does *not* in this case mean
        logical "xor".
        """

        if isinstance(left, GapObj):
            return left._pow_(left.parent(right))
        else:
            return right.parent(left)._pow_(right)

    cpdef _pow_(self, other):
        r"""
        Exponentiation of two GapObj objects.

        EXAMPLES::

            >>> r = gap(5) ^ 2; r
            25
            >>> type(r)
            <class 'gappy.gapobj.GapInteger'>
            >>> r = 5 ^ gap(2); r
            25
            >>> type(r)
            <class 'gappy.gapobj.GapInteger'>
            >>> g, = gap.CyclicGroup(5).GeneratorsOfGroup()
            >>> g ^ 5
            <identity> of ...

        TESTS:

        Check that this can be interrupted gracefully::

            >>> from cysignals.alarm import alarm, AlarmInterrupt
            >>> a, b = gap.GL(1000, 3).GeneratorsOfGroup(); g = a * b
            >>> try:
            ...     alarm(0.5); g ^ (2 ^ 10000)
            ... except AlarmInterrupt:
            ...     print('interrupted long computation')
            ...
            interrupted long computation

            >>> gap.CyclicGroup(2) ^ 2
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found!
            Error, no 1st choice method found for `^' on 2 arguments

            >>> gap(3) ^ gap.infinity
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found! Error, no 1st choice
            method found for `InverseMutable' on 1 arguments
        """
        try:
            sig_GAP_Enter()
            sig_on()
            result = POW(self.value, (<GapObj>other).value)
            sig_off()
        finally:
            GAP_Leave()
        return make_any_gap_obj(self._parent, result)

    cpdef _pow_int(self, other):
        """
        TESTS::

            >>> gap(5)._pow_int(int(2))
            25
        """
        return self._pow_(self._parent(other))

    def is_function(self):
        """
        Return whether the wrapped GAP object is a function.

        OUTPUT:

        Boolean.

        EXAMPLES::

            >>> a = gap.eval("NormalSubgroups")
            >>> a.is_function()
            True
            >>> a = gap(2/3)
            >>> a.is_function()
            False
        """
        return IS_FUNC(self.value)

    def is_list(self):
        r"""
        Return whether the wrapped GAP object is a GAP List.

        OUTPUT:

        Boolean.

        EXAMPLES::

            >>> gap.eval('[1, 2,,,, 5]').is_list()
            True
            >>> gap.eval('3/2').is_list()
            False
        """
        return bool(GAP_IsList(self.value))

    def is_record(self):
        r"""
        Return whether the wrapped GAP object is a GAP record.

        OUTPUT:

        Boolean.

        EXAMPLES::

            >>> gap.eval('[1, 2,,,, 5]').is_record()
            False
            >>> gap.eval('rec(a:=1, b:=3)').is_record()
            True
        """
        return bool(GAP_IsRecord(self.value))

    cpdef is_bool(self):
        r"""
        Return whether the wrapped GAP object is a GAP boolean.

        OUTPUT:

        Boolean.

        EXAMPLES::

            >>> gap(True).is_bool()
            True
        """
        libgap = self.parent()
        cdef GapObj r_sage = libgap.IsBool(self)
        cdef Obj r_gap = r_sage.value
        return r_gap == GAP_True

    def is_string(self):
        r"""
        Return whether the wrapped GAP object is a GAP string.

        OUTPUT:

        Boolean.

        EXAMPLES::

            >>> gap('this is a string').is_string()
            True
        """
        return bool(GAP_IsString(self.value))

    def is_permutation(self):
        r"""
        Return whether the wrapped GAP object is a GAP permutation.

        OUTPUT:

        Boolean.

        EXAMPLES::

            >>> perm = gap.PermList( gap([1,5,2,3,4]) );  perm
            (2,5,4,3)
            >>> perm.is_permutation()
            True
            >>> gap('this is a string').is_permutation()
            False
        """
        return (TNUM_OBJ(self.value) == T_PERM2 or
                TNUM_OBJ(self.value) == T_PERM4)


############################################################################
### GapInteger #############################################################
############################################################################

cdef GapInteger make_GapInteger(parent, Obj obj):
    r"""
    Turn a GAP integer object into a GapInteger Sage object

    EXAMPLES::

        >>> gap(123)
        123
        >>> type(_)
        <class 'gappy.gapobj.GapInteger'>
    """
    cdef GapInteger r = GapInteger.__new__(GapInteger)
    r._initialize(parent, obj)
    return r


cdef class GapInteger(GapObj):
    r"""
    Derived class of GapObj for GAP integers.

    EXAMPLES::

        >>> i = gap(123)
        >>> type(i)
        <class 'gappy.gapobj.GapInteger'>
        >>> i
        123
    """

    cpdef is_C_int(self):
        r"""
        Return whether the wrapped GAP object is a immediate GAP integer.

        An immediate integer is one that is stored as a C integer, and
        is subject to the usual size limits. Larger integers are
        stored in GAP as GMP integers.

        OUTPUT:

        Boolean.

        EXAMPLES::

            >>> n = gap(1)
            >>> type(n)
            <class 'gappy.gapobj.GapInteger'>
            >>> n.is_C_int()
            True
            >>> n.IsInt()
            true

            >>> N = gap(2**130)
            >>> type(N)
            <class 'gappy.gapobj.GapInteger'>
            >>> N.is_C_int()
            False
            >>> N.IsInt()
            true
        """
        return bool(GAP_IsSmallInt(self.value))

    def __int__(self):
        r"""
        Convert a GAP integer to a Python `int`.

        TESTS::

            >>> int(gap(3))
            3
            >>> type(_)
            <class 'int'>
            >>> int(gap(-3))
            -3
            >>> type(_)
            <class 'int'>

            >>> int(gap(2**128))
            340282366920938463463374607431768211456
            >>> type(_)
            <class 'int'>
            >>> int(gap(-2**128))
            -340282366920938463463374607431768211456
            >>> type(_)
            <class 'int'>
        """

        cdef Int size, sign
        cdef size_t nbits
        cdef mpz_t z

        if self.is_C_int():
            # This should work, but there should be a function for this; see
            # https://github.com/gap-system/gap/issues/4208
            # Previously this used the internal function INT_INTOBJ, but in the
            # effort to not use internal functions it's replaced with this
            # instead (which is effectively the same as what INT_INTOBJ does).
            if <Int>self.value < 0:
                # ensure arithmetic right-shift; the compiler might optimize
                # this out but let's see...
                return ((<Int>self.value) >> 2) | ~(~0 >> 2)
            else:
                return <Int>self.value >> 2
        else:
            mpz_init(z)
            try:
                GAP_Enter()
                size = GAP_SizeInt(self.value)
                sign = (size > 0) - (size < 0)
                # Import limbs from GAP
                mpz_import(z, size * sign, -1, sizeof(UInt), 0, 0,
                           GAP_AddrInt(self.value))
            except:
                mpz_clear(z)
            finally:
                GAP_Leave()

            # Determine number of bits needed to represent z
            nbits = mpz_sizeinbase(z, 2)
            # Minimum number of limbs needed for the Python int
            # e.g. if 2**30 we require 31 bits and with PyLong_SHIFT = 30
            # this returns 2
            x = _PyLong_New((nbits + PyLong_SHIFT - 1) // PyLong_SHIFT)
            mpz_export((<py_long>x).ob_digit, NULL, -1, sizeof(digit), 0,
                       (sizeof(digit) * 8) - PyLong_SHIFT, z)
            x *= sign
            mpz_clear(z)
            return x

    def __index__(self):
        r"""
        TESTS:

        Check that gap integers can be used as indices (:trac:`23878`)::

            >>> s = 'abcd'
            >>> s[gap(1)]
            'b'
        """
        return int(self)


##########################################################################
### GapFloat #############################################################
##########################################################################

cdef GapFloat make_GapFloat(parent, Obj obj):
    r"""
    Turn a GAP machine float object into a GapFloat Sage object

    EXAMPLES::

        >>> gap(123.5)
        123.5
        >>> type(_)
        <class 'gappy.gapobj.GapFloat'>
    """
    cdef GapFloat r = GapFloat.__new__(GapFloat)
    r._initialize(parent, obj)
    return r

cdef class GapFloat(GapObj):
    r"""
    Derived class of GapObj for GAP floating point numbers.

    EXAMPLES::

        >>> i = gap(123.5)
        >>> type(i)
        <class 'gappy.gapobj.GapFloat'>
        >>> i
        123.5
        >>> float(i)
        123.5
    """

    def __float__(self):
        r"""
        TESTS::

            >>> float(gap.eval("Float(3.5)"))
            3.5
        """
        return VAL_MACFLOAT(self.value)



############################################################################
### GapIntegerMod ##########################################################
############################################################################

cdef GapIntegerMod make_GapIntegerMod(parent, Obj obj):
    r"""
    Turn a GAP integer object into a :class:`GapIntegerMod` Sage object

    EXAMPLES::

        >>> n = IntegerModRing(123)(13)
        >>> gap(n)
        ZmodnZObj( 13, 123 )
        >>> type(_)
        <class 'gappy.gapobj.GapIntegerMod'>
    """
    cdef GapIntegerMod r = GapIntegerMod.__new__(GapIntegerMod)
    r._initialize(parent, obj)
    return r

cdef class GapIntegerMod(GapObj):
    r"""
    Derived class of GapObj for GAP integers modulo an integer.

    EXAMPLES::

        >>> i = gap.eval('One(ZmodnZ(123)) * 13'); i
        ZmodnZObj( 13, 123 )
        >>> type(i)
        <class 'gappy.gapobj.GapIntegerMod'>
    """

    cpdef GapInteger lift(self):
        """
        Return an integer lift.

        OUTPUT:

        A :class:`GapInteger` that equals ``self`` in the integer mod ring.

        EXAMPLES::

            >>> n = gap.eval('One(ZmodnZ(123)) * 13')
            >>> n.lift()
            13
            >>> type(_)
            <class 'gappy.gapobj.GapInteger'>
        """
        return self.Int()


############################################################################
### GapFiniteField #########################################################
############################################################################

cdef GapFiniteField make_GapFiniteField(parent, Obj obj):
    r"""
    Turn a GAP finite field object into a :class:`GapFiniteField` Sage object

    EXAMPLES::

        >>> gap.eval('Z(5)^2')
        Z(5)^2
        >>> type(_)
        <class 'gappy.gapobj.GapFiniteField'>
    """
    cdef GapFiniteField r = GapFiniteField.__new__(GapFiniteField)
    r._initialize(parent, obj)
    return r


cdef class GapFiniteField(GapObj):
    r"""
    Derived class of GapObj for GAP finite field elements.

    EXAMPLES::

        >>> gap.eval('Z(5)^2')
        Z(5)^2
        >>> type(_)
        <class 'gappy.gapobj.GapFiniteField'>
    """

    cpdef GapInteger lift(self):
        """
        Return an integer lift.

        OUTPUT:

        The smallest positive :class:`GapInteger` that equals ``self`` in the
        prime finite field.

        EXAMPLES::

            >>> n = gap.eval('Z(5)^2')
            >>> n.lift()
            4
            >>> type(_)
            <class 'gappy.gapobj.GapInteger'>

            >>> n = gap.eval('Z(25)')
            >>> n.lift()
            Traceback (most recent call last):
            TypeError: not in prime subfield
        """
        if self.DegreeFFE() == 1:
            return self.IntFFE()
        else:
            raise TypeError('not in prime subfield')

    def __int__(self):
        r"""
        TESTS::

            >>> int(gap.eval("Z(53)"))
            2
        """
        return int(self.Int())


############################################################################
### GapCyclotomic ##########################################################
############################################################################

cdef GapCyclotomic make_GapCyclotomic(parent, Obj obj):
    r"""
    Turn a GAP cyclotomic object into a :class:`GapCyclotomic` Sage
    object.

    EXAMPLES::

        >>> gap.eval('E(3)')
        E(3)
        >>> type(_)
        <class 'gappy.gapobj.GapCyclotomic'>
    """
    cdef GapCyclotomic r = GapCyclotomic.__new__(GapCyclotomic)
    r._initialize(parent, obj)
    return r


cdef class GapCyclotomic(GapObj):
    r"""
    Derived class of GapObj for GAP universal cyclotomics.

    EXAMPLES::

        >>> gap.eval('E(3)')
        E(3)
        >>> type(_)
        <class 'gappy.gapobj.GapCyclotomic'>
    """


############################################################################
### GapRational ############################################################
############################################################################

cdef GapRational make_GapRational(parent, Obj obj):
    r"""
    Turn a GAP Rational number (of type ``Obj``) into a Cython ``GapRational``.

    EXAMPLES::

        >>> from fractions import Fraction
        >>> gap(Fraction(123, 456))
        41/152
        >>> type(_)
        <class 'gappy.gapobj.GapRational'>
    """
    cdef GapRational r = GapRational.__new__(GapRational)
    r._initialize(parent, obj)
    return r


cdef class GapRational(GapObj):
    r"""
    Derived class of GapObj for GAP rational numbers.

    EXAMPLES::

        >>> from fractions import Fraction
        >>> r = gap(Fraction(123, 456))
        >>> type(r)
        <class 'gappy.gapobj.GapRational'>
    """


############################################################################
### GapRing ################################################################
############################################################################

cdef GapRing make_GapRing(parent, Obj obj):
    r"""
    Turn a GAP integer object into a :class:`GapRing` Sage object.

    EXAMPLES::

        >>> gap(GF(5))
        GF(5)
        >>> type(_)
        <class 'gappy.gapobj.GapRing'>
    """
    cdef GapRing r = GapRing.__new__(GapRing)
    r._initialize(parent, obj)
    return r


cdef class GapRing(GapObj):
    r"""
    Derived class of GapObj for GAP rings (parents of ring elements).

    EXAMPLES::

        >>> i = gap.Integers
        >>> type(i)
        <class 'gappy.gapobj.GapRing'>
    """


############################################################################
### GapBoolean #############################################################
############################################################################

cdef GapBoolean make_GapBoolean(parent, Obj obj):
    r"""
    Turn a GAP Boolean number (of type ``Obj``) into a Cython ``GapBoolean``.

    EXAMPLES::

        >>> gap(True)
        true
        >>> type(_)
        <class 'gappy.gapobj.GapBoolean'>
    """
    cdef GapBoolean r = GapBoolean.__new__(GapBoolean)
    r._initialize(parent, obj)
    return r


cdef class GapBoolean(GapObj):
    r"""
    Derived class of GapObj for GAP boolean values.

    EXAMPLES::

        >>> b = gap(True)
        >>> type(b)
        <class 'gappy.gapobj.GapBoolean'>
    """

    def __nonzero__(self):
        """
        Check that the boolean is "true".

        This is syntactic sugar for using libgap. See the examples below.

        OUTPUT:

        Boolean.

        EXAMPLES::

            >>> gap_bool = [gap.eval('true'), gap.eval('false'), gap.eval('fail')]
            >>> for x in gap_bool:
            ...     if x:     # this calls __nonzero__
            ...         print("{} {}".format(x, type(x)))
            true <class 'gappy.gapobj.GapBoolean'>

            >>> for x in gap_bool:
            ...     if not x:     # this calls __nonzero__
            ...         print("{} {}".format( x, type(x)))
            false <class 'gappy.gapobj.GapBoolean'>
            fail <class 'gappy.gapobj.GapBoolean'>
        """
        return self.value == GAP_True


############################################################################
### GapString ##############################################################
############################################################################

cdef GapString make_GapString(parent, Obj obj):
    r"""
    Turn a GAP String (of type ``Obj``) into a Cython ``GapString``.

    EXAMPLES::

        >>> gap('this is a string')
        "this is a string"
        >>> type(_)
        <class 'gappy.gapobj.GapString'>
    """
    cdef GapString r = GapString.__new__(GapString)
    r._initialize(parent, obj)
    return r


cdef class GapString(GapObj):
    r"""
    Derived class of GapObj for GAP strings.

    EXAMPLES::

        >>> s = gap('string')
        >>> type(s)
        <class 'gappy.gapobj.GapString'>
        >>> s
        "string"
        >>> print(s)
        string
    """

    # TODO: Add other sequence methods for GAP strings
    def __len__(self):
        """
        Return the string length.

        Examples
        --------

        >>> s = gap('foo')
        >>> type(s)
        <class 'gappy.gapobj.GapString'>
        >>> len(s)
        3
        """

        return GAP_LenString(self.value)

    def __str__(self):
        r"""
        Convert this :class:`GapString` to a Python string.

        OUTPUT:

        A Python string.

        EXAMPLES::

            >>> s = gap.eval(' "string" '); s
            "string"
            >>> type(_)
            <class 'gappy.gapobj.GapString'>
            >>> str(s)
            'string'
            >>> type(_)
            <class 'str'>
        """
        s = char_to_str(GAP_CSTR_STRING(self.value))
        return s


############################################################################
### GapFunction ############################################################
############################################################################

cdef GapFunction make_GapFunction(parent, Obj obj):
    r"""
    Turn a GAP C function object (of type ``Obj``) into a Cython ``GapFunction``.

    INPUT:

    - ``parent`` -- the parent of the new :class:`GapObj`

    - ``obj`` -- a GAP function object.

    OUTPUT:

    A :class:`GapFunction` instance.

    EXAMPLES::

        >>> gap.CycleLength
        <GAP function "CycleLength">
        >>> type(_)
        <class 'gappy.gapobj.GapFunction'>
    """
    cdef GapFunction r = GapFunction.__new__(GapFunction)
    r._initialize(parent, obj)
    return r


cdef class GapFunction(GapObj):
    r"""
    Derived class of GapObj for GAP functions.

    To show the GAP documentation for this function, use the ``<func>?`` syntax
    in IPython/Jupyter or call ``print(<func>.help())``, where ``<func>`` is
    this function.

    Examples
    --------

    >>> f = gap.Cycles
    >>> type(f)
    <class 'gappy.gapobj.GapFunction'>

    """

    def __cinit__(self):
        self._doc = None

    @property
    def __name__(self):
        """Return the function's name or "unknown" for unbound functions."""

        return str(self._name())

    cpdef GapObj _name(self):
        """Return the function's name as a `GapString`."""

        return self.parent().NameFunction(self)

    @property
    def __doc__(self):
        """
        The standard Python `help` won't show this, but IPython/Jupyter's
        ``?`` help will.
        """
        return self.help()

    def __repr__(self):
        r"""
        Return a string representation

        OUTPUT:

        String.

        EXAMPLES::

            >>> gap.Orbits
            <GAP function "Orbits">
        """
        return f'<GAP function "{self.__name__}">'

    def __call__(self, *args):
        r"""
        Call syntax for functions.

        INPUT:

        - ``*args`` -- arguments. Will be converted to `GapObj` if
          they are not already of this type.

        OUTPUT:

        A :class:`GapObj` encapsulating the functions return
        value, or ``None`` if it does not return anything.

        EXAMPLES::

            >>> a = gap.NormalSubgroups
            >>> b = gap.SymmetricGroup(4)
            >>> gap.collect()
            >>> a
            <GAP function "NormalSubgroups">
            >>> b
            Sym( [ 1 .. 4 ] )
            >>> sorted(a(b))
            [Group(()),
             Sym( [ 1 .. 4 ] ),
             Alt( [ 1 .. 4 ] ),
             Group([ (1,4)(2,3), (...)(...) ])]

            >>> gap.eval("a := NormalSubgroups")
            <GAP function "NormalSubgroups">
            >>> gap.eval("b := SymmetricGroup(4)")
            Sym( [ 1 .. 4 ] )
            >>> gap.collect()
            >>> sorted(gap.eval('a') (gap.eval('b')))
            [Group(()),
             Sym( [ 1 .. 4 ] ),
             Alt( [ 1 .. 4 ] ),
             Group([ (1,4)(2,3), (...)(...) ])]

            >>> a = gap.eval('a')
            >>> b = gap.eval('b')
            >>> gap.collect()
            >>> sorted(a(b))
            [Group(()),
             Sym( [ 1 .. 4 ] ),
             Alt( [ 1 .. 4 ] ),
             Group([ (1,4)(2,3), (...)(...) ])]

        Not every ``GapObj`` is callable::

            >>> f = gap(3)
            >>> f()
            Traceback (most recent call last):
            ...
            TypeError: 'gappy.gapobj.GapInteger' object is not callable

        We illustrate appending to a list which returns None::

            >>> a = gap([]); a
            [  ]
            >>> a.Add(5); a
            [ 5 ]
            >>> a.Add(10); a
            [ 5, 10 ]

        TESTS::

            >>> s = gap.Sum
            >>> s(gap([1,2]))
            3
            >>> s(gap(1), gap(2))
            Traceback (most recent call last):
            ...
            gappy.exceptions.GAPError: Error, no method found!
            Error, no 1st choice method found for `SumOp' on 2 arguments

            >>> from random import randint
            >>> for i in range(0,100):
            ...     rnd = [randint(-10, 10) for i in range(0, randint(0, 7))]
            ...     # compute the sum in GAP
            ...     _ = gap.Sum(rnd)
            ...     try:
            ...         gap.Sum(*rnd)
            ...         print('This should have triggered a ValueError')
            ...         print('because Sum needs a list as argument')
            ...     except ValueError:
            ...         pass

        Note, for this test the ``Exec`` call outputs to the system stdout,
        bypassing Python's ``sys.stdout`` so the output is not picked up by
        doctest automatically::

            >>> import os, tempfile
            >>> with tempfile.TemporaryFile() as f:
            ...     _ = os.dup2(1, f.fileno())
            ...     gap_exec = gap.eval("Exec")
            ...     gap_exec('echo hello from the shell')
            ...     _ = f.seek(0)
            ...     f.read()
            ...
            b'hello from the shell\n'
        """
        cdef Obj result = NULL
        cdef Obj arglist

        libgap = self.parent()

        try:
            sig_GAP_Enter()
            sig_on()
            arglist = make_gap_list(libgap, args)
            result = GAP_CallFuncList(self.value, arglist)
            sig_off()
        finally:
            GAP_Leave()

        if result == NULL:
            # We called a procedure that does not return anything
            return None

        return make_any_gap_obj(libgap, result)

    def help(self):
        """
        Return the GAP help text for the function, if any exists.

        Roughly equivalent to calling ``?FuncName`` in GAP, but returns the
        result as a string.

        Examples
        --------

        >>> print(gap.SymmetricGroup.help())
        50.1-12 SymmetricGroup
        <BLANKLINE>
        ‣ SymmetricGroup( [filt, ]deg ) ─────────────────────────────────── function
        ‣ SymmetricGroup( [filt, ]dom ) ─────────────────────────────────── function
        ...
        Note  that  permutation  groups  provide  special treatment of
        symmetric and alternating groups, see 43.4.
        """

        cdef bytes line_bytes

        if self._doc is not None:
            return self._doc

        old_text_theme = None
        old_screen_size = None
        libgap = self.parent()
        width = 80  # TODO: Make this customizable?

        try:
            GAP_Enter()

            HELP_GET_MATCHES = libgap.function_factory('HELP_GET_MATCHES')
            SIMPLE_STRING = libgap.function_factory('SIMPLE_STRING')
            matches = HELP_GET_MATCHES(libgap.HELP_KNOWN_BOOKS[0],
                                       SIMPLE_STRING(self._name()), True)

            # HELP_GET_MATCHES returns 'exact' matches and 'topic' matches; in
            # the latter case we always guess the first match is the one we
            # want (it usually is)
            try:
                book, entrynum = next(itertools.chain(*matches))
            except StopIteration:
                return ''

            handler = libgap.HELP_BOOK_HANDLER[book['handler']]

            # Save the old text theme and set it to "none"; in particular to
            # strip out terminal control codes
            try:
                # In the off-chance GAPDoc is not loaded...
                SetGAPDocTextTheme = libgap.function_factory(
                    'SetGAPDocTextTheme')
            except GAPError:
                pass
            else:
                old_text_theme = libgap.eval('GAPDocTextTheme')
                SetGAPDocTextTheme('none')

            # Set the screen width to 80 (otherwise it will produce text with
            # lines up to 4096, the hard-coded maximum line length)
            # Hard-coding this might be a small problem for other functions
            # that depend on screen width, but this seems to be rare...
            SizeScreen = libgap.function_factory('SizeScreen')
            old_screen_size = SizeScreen()
            SizeScreen([width])

            line_info = dict(handler['HelpData'](book, entrynum, 'text'))
            # TODO: Add .get() and other dict methods to GapRecord
            start = line_info.get('start', 0)
            lines = line_info['lines']
            line_bytes = GAP_CSTR_STRING((<GapObj>lines).value)[:len(lines)]
            lines = line_bytes.splitlines()

            # We can get the end of the section by finding the start line of
            # the next section.  AFACT the start line info may be
            # GAPDoc-specific
            if book['handler'] == 'GapDocGAP':
                book, entrynum = handler['MatchNext'](book['bookname'],
                                                      entrynum)
                entry = book['entries'][entrynum - 1]
                end = entry[3] - 1  # the 3-th element is the start line
            else:
                end = len(lines)

            doc = b'\n'.join(lines[start:end])
            # NOTE: There is some metadata in the book object about its
            # encoding type but for now just assuming UTF-8 (which is true
            # e.g. for the GAP Reference Manual)
            self._doc = dedent(doc.decode('utf-8', 'surrogageescape')).strip()
            return self._doc
        finally:
            if old_text_theme is not None:
                SetGAPDocTextTheme(old_text_theme)
            if old_screen_size is not None:
                SizeScreen(old_screen_size)

            GAP_Leave()


############################################################################
### GapMethodProxy #########################################################
############################################################################

cdef GapMethodProxy make_GapMethodProxy(parent, Obj function, GapObj base_object):
    r"""
    Turn a GAP C rec object (of type ``Obj``) into a Cython ``GapRecord``.

    This class implement syntactic sugar so that you can write
    ``gapobj.f()`` instead of ``gap.f(gapobj)`` for any GAP
    function ``f``.

    INPUT:

    - ``parent`` -- the parent of the new :class:`GapObj`

    - ``obj`` -- a GAP function object.

    - ``base_object`` -- The first argument to be inserted into the function.

    OUTPUT:

    A :class:`GapMethodProxy` instance.

    EXAMPLES::

        >>> lst = gap([])
        >>> type( lst.Add )
        <class 'gappy.gapobj.GapMethodProxy'>
    """
    cdef GapMethodProxy r = GapMethodProxy.__new__(GapMethodProxy)
    r._initialize(parent, function)
    r.first_argument = base_object
    return r


cdef class GapMethodProxy(GapFunction):
    r"""
    Helper class returned by ``GapObj.__getattr__``.

    Derived class of GapObj for GAP functions. Like its parent,
    you can call instances to implement function call syntax. The only
    difference is that a fixed first argument is prepended to the
    argument list.

    EXAMPLES::

        >>> lst = gap([])
        >>> lst.Add
        <GAP function "Add">
        >>> type(_)
        <class 'gappy.gapobj.GapMethodProxy'>
        >>> lst.Add(1)
        >>> lst
        [ 1 ]
    """

    def __call__(self, *args):
        """
        Call syntax for methods.

        This method is analogous to
        :meth:`GapFunction.__call__`, except that it inserts a
        fixed :class:`GapObj` in the first slot of the function.

        INPUT:

        - ``*args`` -- arguments. Will be converted to `GapObj` if
          they are not already of this type.

        OUTPUT:

        A :class:`GapObj` encapsulating the functions return
        value, or ``None`` if it does not return anything.

        EXAMPLES::

            >>> lst = gap.eval('[1,,3]')
            >>> lst.Add.__call__(4)
            >>> lst.Add(5)
            >>> lst
            [ 1,, 3, 4, 5 ]
        """
        if len(args) > 0:
            return GapFunction.__call__(self, * ([self.first_argument] + list(args)))
        else:
            return GapFunction.__call__(self, self.first_argument)



############################################################################
### GapList ################################################################
############################################################################

cdef GapList make_GapList(parent, Obj obj):
    r"""
    Turn a GAP C List object (of type ``Obj``) into a Cython ``GapList``.

    EXAMPLES::

        >>> gap([0, 2, 3])
        [ 0, 2, 3 ]
        >>> type(_)
        <class 'gappy.gapobj.GapList'>
    """
    cdef GapList r = GapList.__new__(GapList)
    r._initialize(parent, obj)
    return r


cdef class GapList(GapObj):
    r"""
    Derived class of GapObj for GAP Lists.

    .. NOTE::

        Lists are indexed by `0..len(l)-1`, as expected from
        Python. This differs from the GAP convention where lists start
        at `1`.

    EXAMPLES::

        >>> lst = gap.SymmetricGroup(3).List(); lst
        [ (), (1,3), (1,2,3), (2,3), (1,3,2), (1,2) ]
        >>> type(lst)
        <class 'gappy.gapobj.GapList'>
        >>> len(lst)
        6
        >>> lst[3]
        (2,3)

    We can easily convert a GAP ``List`` object into a Python ``list``::

        >>> list(lst)
        [(), (1,3), (1,2,3), (2,3), (1,3,2), (1,2)]
        >>> type(_)
        <... 'list'>

    Range checking is performed::

        >>> lst[10]
        Traceback (most recent call last):
        ...
        IndexError: index out of range.
    """

    def __bool__(self):
        r"""
        Return True if the list is non-empty, as with Python ``list``s.

        EXAMPLES::

            >>> lst = gap.eval('[1,,,4]')
            >>> bool(lst)
            True
            >>> lst = gap.eval('[]')
            >>> bool(lst)
            False
        """
        return bool(len(self))

    def __len__(self):
        r"""
        Return the length of the list.

        OUTPUT:

        Integer.

        EXAMPLES::

            >>> lst = gap.eval('[1,,,4]')   # a sparse list
            >>> len(lst)
            4
        """
        return GAP_LenList(self.value)

    def __getitem__(self, i):
        r"""
        Return the ``i``-th element of the list.

        As usual in Python, indexing starts at `0` and not at `1` (as
        in GAP). This can also be used with multi-indices.

        INPUT:

        - ``i`` -- integer.

        OUTPUT:

        The ``i``-th element as a :class:`GapObj`.

        EXAMPLES::

            >>> lst = gap.eval('["first",,,"last"]')   # a sparse list
            >>> lst[0]
            "first"

            >>> l = gap.eval('[ [0, 1], [2, 3] ]')
            >>> l[0,0]
            0
            >>> l[0,1]
            1
            >>> l[1,0]
            2
            >>> l[0,2]
            Traceback (most recent call last):
            ...
            IndexError: index out of range
            >>> l[2,0]
            Traceback (most recent call last):
            ...
            IndexError: index out of range
            >>> l[0,0,0]
            Traceback (most recent call last):
            ...
            ValueError: too many indices
        """
        cdef int j
        cdef Obj obj = self.value

        if isinstance(i, tuple):
            for j in i:
                if not GAP_IsList(obj):
                    raise ValueError('too many indices')
                if j < 0 or j >= GAP_LenList(obj):
                    raise IndexError('index out of range')
                obj = GAP_ElmList(obj, j + 1)

        else:
            j = i
            if j < 0 or j >= GAP_LenList(obj):
                raise IndexError('index out of range.')
            obj = GAP_ElmList(obj, j + 1)

        return make_any_gap_obj(self.parent(), obj)

    def __setitem__(self, i, elt):
        r"""
        Set the ``i``-th item of this list

        EXAMPLES::

            >>> l = gap.eval('[0, 1]')
            >>> l
            [ 0, 1 ]
            >>> l[0] = 3
            >>> l
            [ 3, 1 ]

        Contrarily to Python lists, setting an element beyond the limit extends
        the list::

            >>> l[12] = -2
            >>> l
            [ 3, 1,,,,,,,,,,, -2 ]

        This function also handles multi-indices::

            >>> l = gap.eval('[[[0,1],[2,3]],[[4,5], [6,7]]]')
            >>> l[0,1,0] = -18
            >>> l
            [ [ [ 0, 1 ], [ -18, 3 ] ], [ [ 4, 5 ], [ 6, 7 ] ] ]
            >>> l[0,0,0,0]
            Traceback (most recent call last):
            ...
            ValueError: too many indices

        Assignment to immutable objects gives error::

            >>> l = gap([0,1])
            >>> u = l.deepcopy(0)
            >>> u[0] = 5
            Traceback (most recent call last):
            ...
            TypeError: immutable GAP object does not support item assignment

        TESTS::

            >>> m = gap.eval('[[0,0],[0,0]]')
            >>> m[0,0] = 1
            >>> m[0,1] = 2
            >>> m[1,0] = 3
            >>> m[1,1] = 4
            >>> m
            [ [ 1, 2 ], [ 3, 4 ] ]
        """
        if not IS_MUTABLE_OBJ(self.value):
            raise TypeError('immutable GAP object does not support item assignment')

        cdef int j
        cdef Obj obj = self.value

        if isinstance(i, tuple):
            for j in i[:-1]:
                if not GAP_IsList(obj):
                    raise ValueError('too many indices')
                if j < 0 or j >= GAP_LenList(obj):
                    raise IndexError('index out of range')
                obj = GAP_ElmList(obj, j + 1)
            if not GAP_IsList(obj):
                raise ValueError('too many indices')
            j = i[-1]
        else:
            j = i

        if j < 0:
            raise IndexError('index out of range.')

        cdef GapObj celt
        if isinstance(elt, GapObj):
            celt = <GapObj> elt
        else:
            celt= self.parent()(elt)

        GAP_AssList(obj, j + 1, celt.value)


############################################################################
### GapPermutation #########################################################
############################################################################


cdef GapPermutation make_GapPermutation(parent, Obj obj):
    r"""
    Turn a GAP C permutation object (of type ``Obj``) into a Cython
    ``GapPermutation``.

    EXAMPLES::

        >>> gap.eval('(1,3,2)(4,5,8)')
        (1,3,2)(4,5,8)
        >>> type(_)
        <class 'gappy.gapobj.GapPermutation'>
    """
    cdef GapPermutation r = GapPermutation.__new__(GapPermutation)
    r._initialize(parent, obj)
    return r


cdef class GapPermutation(GapObj):
    r"""
    Derived class of GapObj for GAP permutations.

    .. NOTE::

        Permutations in GAP act on the numbers starting with 1.

    EXAMPLES::

        >>> perm = gap.eval('(1,5,2)(4,3,8)')
        >>> type(perm)
        <class 'gappy.gapobj.GapPermutation'>
    """


############################################################################
### GapRecord ##############################################################
############################################################################

cdef GapRecord make_GapRecord(parent, Obj obj):
    r"""
    Turn a GAP C rec object (of type ``Obj``) into a Cython ``GapRecord``.

    EXAMPLES::

        >>> gap.eval('rec(a:=0, b:=2, c:=3)')
        rec( a := 0, b := 2, c := 3 )
        >>> type(_)
        <class 'gappy.gapobj.GapRecord'>
    """
    cdef GapRecord r = GapRecord.__new__(GapRecord)
    r._initialize(parent, obj)
    return r


cdef class GapRecord(GapObj):
    r"""
    Derived class of GapObj for GAP records.

    EXAMPLES::

        >>> rec = gap.eval('rec(a:=123, b:=456)')
        >>> type(rec)
        <class 'gappy.gapobj.GapRecord'>
        >>> len(rec)
        2
        >>> rec['a']
        123

    We can easily convert a GAP ``rec`` object into a Python ``dict``::

        >>> dict(rec)
        {'b': 456, 'a': 123}
        >>> type(_)
        <... 'dict'>

    Range checking is performed::

        >>> rec['no_such_element']
        Traceback (most recent call last):
        ...
        KeyError: 'no_such_element'
    """

    def names(self):
        """
        Returns the list of names in the record.

        Examples
        --------

        >>> rec = gap.eval('rec(a:=123, b:=456, S3:=SymmetricGroup(3))')
        >>> rec.names()
        ['b', 'a', 'S3']
        """

        return [str(n) for n in self._names()]

    cdef GapList _names(self):
        """
        Implementation of `GapList.names` but returns as a `GapList` instead
        of a Python `list`.
        """

        cdef Obj names, RecNames
        cdef Obj args[1]

        try:
            GAP_Enter()
            RecNames = GAP_ValueGlobalVariable('RecNames')
            args[0] = self.value
            names = GAP_CallFuncArray(RecNames, 1, args)
            return make_GapList(self.parent(), names)
        finally:
            GAP_Leave()

    def __len__(self):
        r"""
        Return the length of the record.

        OUTPUT:

        Integer. The number of entries in the record.

        EXAMPLES::

            >>> rec = gap.eval('rec(a:=123, b:=456, S3:=SymmetricGroup(3))')
            >>> len(rec)
            3
        """
        # TODO: Curiously, GAP does not have a built-in function or an API
        # call to get the length of a record.  The internal function LEN_PREC
        # can be used, but otherwise the only way is to use the built-in
        # RecNames function and return its length.
        return len(self._names())

    def __iter__(self):
        r"""
        Iterate over the elements of the record.

        Unlike iterating over a `dict` this returns the key/value pairs in
        the record, which makes it easy to convert to a Python `dict` like
        ``dict(rec)``.

        Examples
        --------

            >>> rec = gap.eval('rec(a:=123, b:=456)')
            >>> iter = rec.__iter__()
            >>> type(iter)
            <class 'generator'>
            >>> sorted(rec)
            [('a', 123), ('b', 456)]

        .. note::

            The names of elements in GAP records are not necessarily returned
            in the same order as they were passed when the record was defined;
            so when converting to a `dict` the key order will be in whatever
            order was returned by GAP's ``RecNames`` function.

            >>> dict(rec)
            {'b': 456, 'a': 123}
        """

        for name in self._names():
            yield (str(name), self._getitem(name))

    def __getitem__(self, name):
        r"""
        Return the ``name``-th element of the GAP record.

        INPUT:

        - ``name`` -- string.

        OUTPUT:

        The record element labelled by ``name`` as a :class:`GapObj`.

        EXAMPLES::

            >>> rec = gap.eval('rec(first:=123, second:=456)')
            >>> rec['first']
            123
        """

        cdef GapString gap_name

        if isinstance(name, GapString):
            gap_name = <GapString>name
        else:
            gap_name = make_GapString(self.parent(), make_gap_string(name))

        return self._getitem(gap_name)

    cdef GapObj _getitem(self, GapString name):
        """Internal implementation for `GapRecord.__getitem__`."""

        cdef Obj result
        try:
            GAP_Enter()
            result = GAP_ElmRecord(self.value, name.value)
            # GAP_ElmRecord does not raise a GAPError like the previous
            # approach did, so just raise a KeyError instead
            if result == NULL:
                raise KeyError(str(name))

            return make_any_gap_obj(self.parent(), result)
        finally:
            GAP_Leave()