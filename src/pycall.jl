# SPDX-License-Identifier: MIT
# See LICENSE.md at https://github.com/pabloferz/DLPack.jl


# This will be used to release the `DLManagedTensor`s and associated array.
const PYCALL_DLPACK_DELETER = @cfunction(release, Cvoid, (Ptr{Cvoid},))


"""
    DLManagedTensor(po::PyObject)

Takes a PyCapsule holding a `DLManagedTensor` and returns the latter.
"""
function DLManagedTensor(po::PyCall.PyObject)
    if !PyCall.pyisinstance(po, PyCall.@pyglobalobj(:PyCapsule_Type))
        throw(ArgumentError("PyObject must be a PyCapsule"))
    end

    name = PyCall.@pycheck ccall(
        (PyCall.@pysym :PyCapsule_GetName), Ptr{Cchar}, (PyCall.PyPtr,), po
    )

    if unsafe_string(name) == "used_dltensor"
        throw(ArgumentError("PyCapsule in use, have you wrapped it already?"))
    end

    dlptr = PyCall.@pycheck ccall(
        (PyCall.@pysym :PyCapsule_GetPointer),
        Ptr{DLManagedTensor}, (PyCall.PyPtr, Ptr{Cchar}),
        po, name
    )

    tensor = DLManagedTensor(dlptr)

    # Replace the capsule name to "used_dltensor"
    set_name_flag = PyCall.@pycheck ccall(
        (PyCall.@pysym :PyCapsule_SetName),
        Cint, (PyCall.PyPtr, Ptr{Cchar}),
        po, USED_PYCAPSULE_NAME
    )
    if set_name_flag != 0
        @warn("Could not mark PyCapsule as used")
    end

    # Extra precaution: Replace the capsule destructor to prevent it from deleting the
    # tensor. We will use the `DLManagedTensor.deleter` instead.
    PyCall.@pycheck ccall(
        (PyCall.@pysym :PyCapsule_SetDestructor),
        Cint, (PyCall.PyPtr, Ptr{Cvoid}),
        po, C_NULL
    )

    return tensor
end

"""
    wrap(o::PyObject, to_dlpack)

Takes a tensor `o::PyObject` and a `to_dlpack` function that generates a
`DLManagedTensor` bundled in a PyCapsule, and returns a zero-copy
`array::AbstractArray` pointing to the same data in `o`.
For tensors with row-major ordering the resulting array will have all
dimensions reversed.
"""
function wrap(o::PyCall.PyObject, to_dlpack::Union{PyCall.PyObject, Function})
    return unsafe_wrap(DLManagedTensor(to_dlpack(o)), o)
end

"""
    wrap(::Type{<: AbstractArray{T, N}}, ::Type{<: MemoryLayout}, o::PyObject, to_dlpack)

Type-inferrable alternative to `wrap(o, to_dlpack)`.
"""
function wrap(::Type{A}, ::Type{M}, o::PyCall.PyObject, to_dlpack) where {
    T, N, A <: AbstractArray{T, N}, M
}
    return unsafe_wrap(A, M, DLManagedTensor(to_dlpack(o)), o)
end

"""
    share(A::StridedArray, from_dlpack::PyObject)

Takes a Julia array and an external `from_dlpack` method that consumes PyCapsules
following the DLPack protocol. Returns a Python tensor that shares the data with `A`.
The resulting tensor will have all dimensions reversed with respect
to the Julia array.
"""
function share(A::StridedArray, from_dlpack::PyCall.PyObject)
    return share(A, PyCall.PyObject, from_dlpack)
end

"""
    share(A::StridedArray, ::Type{PyObject}, from_dlpack)

Similar to `share(A, from_dlpack::PyObject)`. Use when there is a need to
disambiguate the return type.
"""
function share(A::StridedArray, ::Type{PyCall.PyObject}, from_dlpack)
    capsule = share(A)
    tensor = capsule.tensor
    tensor_ptr = pointer_from_objref(tensor)

    # Prevent `A` and `tensor` from being `gc`ed while `o` is around.
    # For certain DLPack-compatible libraries, e.g. PyTorch, the tensor is
    # captured and the `deleter` referenced from it.
    SHARES_POOL[tensor_ptr] = (capsule, A)
    tensor.deleter = PYCALL_DLPACK_DELETER

    pycapsule = PyCall.PyObject(PyCall.@pycheck ccall(
        (PyCall.@pysym :PyCapsule_New),
        PyCall.PyPtr, (Ptr{Cvoid}, Ptr{Cchar}, Ptr{Cvoid}),
        tensor_ptr, PYCAPSULE_NAME, C_NULL
    ))

    return from_dlpack(pycapsule)
end
