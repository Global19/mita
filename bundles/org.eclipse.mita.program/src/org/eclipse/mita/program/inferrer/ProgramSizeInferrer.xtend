/********************************************************************************
 * Copyright (c) 2017, 2018 Bosch Connected Devices and Solutions GmbH.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * Contributors:
 *    Bosch Connected Devices and Solutions GmbH - initial contribution
 *
 * SPDX-License-Identifier: EPL-2.0
 ********************************************************************************/

package org.eclipse.mita.program.inferrer

import com.google.inject.Inject
import java.util.HashMap
import java.util.LinkedList
import java.util.List
import org.eclipse.emf.ecore.EObject
import org.eclipse.emf.ecore.resource.Resource
import org.eclipse.emf.ecore.util.EcoreUtil.UsageCrossReferencer
import org.eclipse.mita.base.expressions.ArrayAccessExpression
import org.eclipse.mita.base.expressions.AssignmentExpression
import org.eclipse.mita.base.expressions.ElementReferenceExpression
import org.eclipse.mita.base.expressions.PrimitiveValueExpression
import org.eclipse.mita.base.expressions.ValueRange
import org.eclipse.mita.base.types.CoercionExpression
import org.eclipse.mita.base.types.TypeReferenceSpecifier
import org.eclipse.mita.base.typesystem.BaseConstraintFactory
import org.eclipse.mita.base.typesystem.infra.AbstractSizeInferrer
import org.eclipse.mita.base.typesystem.infra.NicerTypeVariableNamesForErrorMessages
import org.eclipse.mita.base.typesystem.solver.ConstraintSolution
import org.eclipse.mita.base.typesystem.solver.ConstraintSystem
import org.eclipse.mita.base.typesystem.solver.Substitution
import org.eclipse.mita.base.typesystem.types.AbstractType
import org.eclipse.mita.base.typesystem.types.ProdType
import org.eclipse.mita.base.typesystem.types.SumType
import org.eclipse.mita.base.typesystem.types.TypeVariable
import org.eclipse.mita.base.util.BaseUtils
import org.eclipse.mita.base.util.PreventRecursion
import org.eclipse.mita.platform.AbstractSystemResource
import org.eclipse.mita.platform.SystemResourceAlias
import org.eclipse.mita.program.FunctionDefinition
import org.eclipse.mita.program.GeneratedFunctionDefinition
import org.eclipse.mita.program.NewInstanceExpression
import org.eclipse.mita.program.Program
import org.eclipse.mita.program.ReturnStatement
import org.eclipse.mita.program.SystemResourceSetup
import org.eclipse.mita.program.VariableDeclaration
import org.eclipse.mita.program.model.ModelUtils
import org.eclipse.mita.program.resource.PluginResourceLoader
import org.eclipse.xtext.EcoreUtil2


import static extension org.eclipse.mita.base.util.BaseUtils.castOrNull
import static extension org.eclipse.mita.base.util.BaseUtils.force
import java.util.HashSet
import com.google.common.base.Optional
import org.eclipse.xtend.lib.annotations.Accessors
import org.eclipse.mita.base.typesystem.infra.NullSizeInferrer
import org.eclipse.mita.base.typesystem.infra.ElementSizeInferrer
import org.eclipse.xtend.lib.annotations.FinalFieldsConstructor
import org.eclipse.mita.base.typesystem.infra.MitaBaseResource
import org.eclipse.mita.base.types.TypeUtils
import static org.eclipse.mita.base.types.TypeUtils.*
import static extension org.eclipse.mita.base.types.TypeUtils.ignoreCoercions
import org.eclipse.mita.base.types.PresentTypeSpecifier

/**
 * Hierarchically infers the size of a data element.
 */
class ProgramSizeInferrer extends AbstractSizeInferrer implements ElementSizeInferrer {

	@Inject
	protected PluginResourceLoader loader;

	PreventRecursion preventRecursion = new PreventRecursion;
	
	@Accessors 
	ElementSizeInferrer delegate = new NullSizeInferrer();
	
	static def ElementSizeInferrer orElse(ElementSizeInferrer i1, ElementSizeInferrer i2) {
		if(i1 !== null && i2 !== null) {
			return new Combination(i1, i2);
		}
		else {
			return i1?:i2;
		}
	}
	
	override ConstraintSolution inferSizes(ConstraintSolution cs, Resource r) {
		val system = new ConstraintSystem(cs.constraintSystem);
		val sub = new Substitution(cs.solution);
		val toBeInferred = unbindSizes(system, sub, r).force;
		/* All modified types need to have their size inferred.
		 * Size inferrers may only recurse on contained objects, but may otherwise follow references freely.
		 * That means that infer(ElementReferenceExpression r) may not call infer(r.reference), but may look at all other already available information.
		 * This means that sometimes it may not be possible to infer the size for something right now, we are waiting for another size to be inferred.
		 * In that case infer returns its arguments and they are added to the end of the queue.
		 * To prevent endless loops we require that in each full run of the queue there are less objects re-inserted than removed.
		 * For this we keep track of all re-inserted elements and clear this set whenever we didn't reinsert something. 
		 */
		val reInserted = new HashSet<Pair<EObject, AbstractType>>();
		while(!toBeInferred.empty && reInserted.size < toBeInferred.size) {
			val obj_type = toBeInferred.remove(0);
			val toReInsert = startInference(system, sub, r, MitaBaseResource.resolveProxy(r, obj_type.key), sub.applyToType(obj_type.value));
			if(toReInsert.present) {
				toBeInferred.add(toReInsert.get);
				reInserted.add(toReInsert.get);
			}
			else {
				reInserted.clear();
			}
		}
		
		return new ConstraintSolution(system, sub, cs.issues);	
	}
	
	def Iterable<Pair<EObject, AbstractType>> unbindSizes(ConstraintSystem system, Substitution sub, Resource r) {
		val unbindings = new HashMap<TypeVariable, AbstractType>();
		sub.content.forEach[int i, t | 
			if(TypeUtils.isGeneratedType(system, t)) {
				val typeInferrerCls = system.getUserData(t, BaseConstraintFactory.SIZE_INFERRER_KEY);
				val typeInferrer = loader.loadFromPlugin(r, typeInferrerCls)?.castOrNull(ElementSizeInferrer);
				if(typeInferrer !== null) {
					val newType = typeInferrer.unbindSize(system, t);
					if(newType !== t) {
						unbindings.put(sub.idxToTypeVariable.get(i), newType);
					}
				}
			}
		]
		sub.add(unbindings);
		
		return unbindings.entrySet.map[it.key.origin -> it.value].filter[it.key !== null];
	}
	
	def getInferrer(ConstraintSystem system, Resource r, EObject objOrProxy, AbstractType type) {
		val obj = MitaBaseResource.resolveProxy(r, objOrProxy);
		val typeInferrerCls = if(TypeUtils.isGeneratedType(system, type)) {
			system.getUserData(type, BaseConstraintFactory.SIZE_INFERRER_KEY);
		}
		val typeInferrer = if(typeInferrerCls !== null) { 
			loader.loadFromPlugin(r, typeInferrerCls)?.castOrNull(ElementSizeInferrer) => [
				it?.setDelegate(this)]
		}
		
		// all generated elements may supply an inferrer
		// function calls
		val functionInferrerCls = if(obj instanceof ElementReferenceExpression) {
			if(obj.operationCall) {
				val ref = obj.reference;
				if(ref instanceof GeneratedFunctionDefinition) {
					ref.sizeInferrer;
				}
			}
		}
		val functionInferrer = if(functionInferrerCls !== null) { 
			loader.loadFromPlugin(obj.eResource, typeInferrerCls)?.castOrNull(ElementSizeInferrer) => [
				it?.setDelegate(this)
			]
		};
		
//		// system resources
//		val systemResourceInferrerCls = obj.getRelevantSystemResource()?.sizeInferrer;
//		val systemResourceInferrer = if(systemResourceInferrerCls !== null) { loader.loadFromPlugin(obj.eResource, systemResourceInferrerCls) };
		
		return functionInferrer.orElse(typeInferrer)
	}
	
	// only generated types have special needs for size inference for now
	def Optional<Pair<EObject, AbstractType>> startInference(ConstraintSystem system, Substitution sub, Resource r, EObject obj, AbstractType type) {		
		val inferrer = getInferrer(system, r, obj, type);
		
		// the result of the first argument to ?: is null iff both inferrers are null (or the inferrer didn't follow the contract).
		// Then nobody wants to infer anything for this type and we return success.
		// from how this function is called that should never happen, since somebody unbound a type,
		// but its better to reason locally and not introduce a global dependency.
		return inferrer?.infer(system, sub, r, obj, type) ?: Optional.absent;
	}
	
	def void inferUnmodifiedFrom(ConstraintSystem system, Substitution sub, EObject target, EObject delegate) {
		sub.add(system.getTypeVariable(target), system.getTypeVariable(delegate));
	}
	
	override Optional<Pair<EObject, AbstractType>> infer(ConstraintSystem system, Substitution sub, Resource r, EObject obj, AbstractType type) {
		doInfer(system, sub, r, obj, type);
	}
	
	dispatch def Optional<Pair<EObject, AbstractType>> doInfer(ConstraintSystem system, Substitution sub, Resource r, ElementReferenceExpression obj, AbstractType type) {
		inferUnmodifiedFrom(system, sub, obj, obj.reference);
		return Optional.absent();
	}
	
	dispatch def Optional<Pair<EObject, AbstractType>> doInfer(ConstraintSystem system, Substitution sub, Resource r, CoercionExpression obj, AbstractType type) {
		inferUnmodifiedFrom(system, sub, obj, obj.value);
		return Optional.absent();
	}
	
	dispatch def Optional<Pair<EObject, AbstractType>> doInfer(ConstraintSystem system, Substitution sub, Resource r, VariableDeclaration variable, AbstractType type) {
		val variableRoot = EcoreUtil2.getContainerOfType(variable, Program);
		val referencesToVariable = UsageCrossReferencer.find(variable, variableRoot).map[e | e.EObject ];
		val typeOrigin = (variable.typeSpecifier.castOrNull(PresentTypeSpecifier) ?: variable.initialization) ?: (
			referencesToVariable
				.map[it.eContainer]
				.filter(AssignmentExpression)
				.filter[ae |
					val left = ae.varRef; 
					left instanceof ElementReferenceExpression && (left as ElementReferenceExpression).reference === variable 
				]
				.map[it.expression]
				.head
		)
		if(typeOrigin !== null) {
			inferUnmodifiedFrom(system, sub, variable, typeOrigin);
		}
		return Optional.absent();
	}
	
	dispatch def Optional<Pair<EObject, AbstractType>> doInfer(ConstraintSystem system, Substitution sub, Resource r, PrimitiveValueExpression obj, AbstractType type) {
		inferUnmodifiedFrom(system, sub, obj, obj.value);
		return Optional.absent();
	}
	
	dispatch def Optional<Pair<EObject, AbstractType>> doInfer(ConstraintSystem system, Substitution sub, Resource r, EObject obj, AbstractType type) {
		return Optional.absent();
	}
	
//	/*
//	 * Walks to referenced system resources.
//	 * Which kinds of ways are there to do this?
//	 * a.b.read()
//	 */
//	
//	dispatch def AbstractSystemResource getRelevantSystemResource(ElementReferenceExpression ref) {
//		
//	}
//
//	dispatch def AbstractSystemResource getRelevantSystemResource(EObject ref) {
//		
//	}
	
	
	
	
	
	
	
	
	
	
	
	
	def ElementSizeInferenceResult infer(EObject obj) {
		val type = BaseUtils.getType(obj);
		if(TypeUtils.isGeneratedType(obj, type)) {
			return obj._doInferFromType(type);
		}
		return obj.doInfer(type);
	}
		
	protected def dispatch ElementSizeInferenceResult doInfer(FunctionDefinition obj, AbstractType type) {
		return PreventRecursion.preventRecursion(this.class.simpleName -> obj, [
			val allReturnSizes = obj.eAllContents.filter(ReturnStatement).map[x | 
				x.infer
			].toList();
			var result = if(allReturnSizes.empty) {
				obj.inferFromType(type)
			} else if(allReturnSizes.size == 1) {
				allReturnSizes.head;
			} else {
				val invalidResults = allReturnSizes.filter(InvalidElementSizeInferenceResult);
				if(!invalidResults.isEmpty) {
					invalidResults.head;
				} else {
					newValidResult(obj, allReturnSizes.filter(ValidElementSizeInferenceResult).map[x | x.elementCount ].max);				
				}
			}
			
			return result
		], [|
			return newInvalidResult(obj, '''Function "«obj.name»" is recursive. Cannot infer size.''')
		]);
	}
	
	protected def dispatch ElementSizeInferenceResult doInfer(ArrayAccessExpression obj, AbstractType type) {
		val accessor = obj.arraySelector.ignoreCoercions;
		if(accessor instanceof ValueRange) {
			val maxResult = obj.owner.infer;
			if(maxResult instanceof ValidElementSizeInferenceResult) {
				var long elementCount = maxResult.elementCount;
				
				if(accessor.lowerBound !== null) {
					val lowerBound = StaticValueInferrer.infer(accessor.lowerBound, [x|]);
					elementCount -= (lowerBound as Long) ?: Long.valueOf(0);
				}	
				if(accessor.upperBound !== null) {
					val upperBound = StaticValueInferrer.infer(accessor.upperBound, [x|]);
					elementCount -= maxResult.elementCount - ((upperBound as Long) ?: Long.valueOf(0));
				}
				
				val result = new ValidElementSizeInferenceResult(maxResult.root, maxResult.typeOf, elementCount);
				result.children += maxResult.children;
				return result;
			}
			return maxResult;
		}
		else {
			return obj.inferFromType(type)
		}
	}
	
	protected def dispatch ElementSizeInferenceResult doInfer(ElementReferenceExpression obj, AbstractType type) {
		val inferredSize = obj.inferFromType(type);
		if (inferredSize instanceof ValidElementSizeInferenceResult) {
			return inferredSize;
		}
		val result = obj.reference.infer;
		return result.replaceRoot(obj);
	}

	protected def dispatch ElementSizeInferenceResult doInfer(ReturnStatement obj, AbstractType type) {
		if(obj.value === null) {
			return newInvalidResult(obj, "Return statements without values do not have a size");
		} else {
			return obj.value.infer;
		}
	}
	
	protected def dispatch ElementSizeInferenceResult doInfer(NewInstanceExpression obj, AbstractType type) {
		return obj.inferFromType(type);
	}
	

	protected def dispatch ElementSizeInferenceResult doInfer(VariableDeclaration variable, AbstractType type) {
		val variableRoot = EcoreUtil2.getContainerOfType(variable, Program);
		val referencesToVariable = UsageCrossReferencer.find(variable, variableRoot).map[e | e.EObject ];
		val initialization = variable.initialization ?: (
			referencesToVariable
				.map[it.eContainer]
				.filter(AssignmentExpression)
				.filter[ae |
					val left = ae.varRef; 
					left instanceof ElementReferenceExpression && (left as ElementReferenceExpression).reference === variable 
				]
				.map[it.expression]
				.head
		)
		if(initialization === null) {
			variable.inferFromType(type);
		} else {
			return initialization.infer;
		}
	}
	protected def dispatch ElementSizeInferenceResult doInfer(PrimitiveValueExpression obj, AbstractType type) {
		return obj.value.infer;
	}
	
	protected def dispatch ElementSizeInferenceResult doInfer(EObject obj, AbstractType type) {
		// fallback: try and infer based on the type of the expression
		return obj.inferFromType(type);
	}
	
	protected def dispatch ElementSizeInferenceResult doInfer(Object obj, AbstractType type) {
		return newInvalidResult(null, "Unable to infer size from " + obj.class.simpleName);
	}
		
	protected def dispatch ElementSizeInferenceResult doInfer(Void obj, AbstractType type) {
		return newInvalidResult(null, "Unable to infer size from nothing");
	}
	
	protected def ElementSizeInferenceResult inferFromType(EObject obj, AbstractType type) {
		doInferFromType(obj, type);
	}
	
	protected dispatch def ElementSizeInferenceResult doInferFromType(EObject obj, AbstractType type) {
		// this expression has an immediate value (akin to the StaticValueInferrer)
		if (ModelUtils.isPrimitiveType(type, obj) || type?.name == "Exception") {
			// it's a primitive type
			return new ValidElementSizeInferenceResult(obj, type, 1);
		} else if (isGeneratedType(obj, type)) {
			// it's a generated type, so we must load the inferrer
			var ElementSizeInferrer inferrer = null;
			
			// if its a platform component, the component specifies its own inferrer
			val instance = if(obj instanceof ElementReferenceExpression) {
				if(obj.isOperationCall && obj.arguments.size > 0) {
					obj.arguments.head.value; 
				}
			}
			if(instance !== null) {
				if(instance instanceof ElementReferenceExpression) {
					val resourceRef = instance.arguments.head?.value;
					if(resourceRef instanceof ElementReferenceExpression) {
						var resourceSetup = resourceRef.reference;
						var Object loadedInferrer = null;
						if(resourceSetup instanceof SystemResourceAlias) {
							resourceSetup = resourceSetup.delegate;
						}
						if(resourceSetup instanceof SystemResourceSetup) {
							val resource = resourceSetup.type;
							loadedInferrer = loader.loadFromPlugin(resource.eResource, resource.sizeInferrer);	
						}
						else if(resourceSetup instanceof AbstractSystemResource) {
							loadedInferrer = loader.loadFromPlugin(resourceSetup.eResource, resourceSetup.sizeInferrer);	
						}
						// we're done loading, let's see if we actually loaded an ESI
						if(loadedInferrer instanceof ElementSizeInferrer) {
							inferrer = loadedInferrer;
						}
						// if we got something else we should warn about this. We could either throw an exception or try to recover by deferring to the default inferrer, but log a warning.
						else if(loadedInferrer !== null) {
							println('''[WARNING] Expected an instance of ElementSizeInferrer, got: «loadedInferrer.class.simpleName»''')
						}
					}
				}
			}
			
			val loadedTypeInferrer = loader.loadFromPlugin(obj.eResource, TypeUtils.getConstraintSystem(obj.eResource).getUserData(type, BaseConstraintFactory.SIZE_INFERRER_KEY));
			
			if(loadedTypeInferrer instanceof ElementSizeInferrer) {			
				inferrer = inferrer.orElse(loadedTypeInferrer);	
			}
			
			val finalInferrer = inferrer;
			if (finalInferrer === null) {
				return new InvalidElementSizeInferenceResult(obj, type, "Type has no size inferrer");
			} 
//			else {
//				
//				return PreventRecursion.preventRecursion(this.class.simpleName -> obj, 
//				[|
//					return finalInferrer.doInfer(obj, type);
//				], [|
//					val renamer = new NicerTypeVariableNamesForErrorMessages();
//					return newInvalidResult(obj, '''Cannot infer size of "«obj.class.simpleName»" of type "«type.modifyNames(renamer)»".''')
//				])
//			}
		}
		val renamer = new NicerTypeVariableNamesForErrorMessages;
		return newInvalidResult(obj, "Unable to infer size from type " + type.modifyNames(renamer));
	}
	
	protected dispatch def ElementSizeInferenceResult doInferFromType(EObject context, Void type) {
		return newInvalidResult(context, '''Unable to infer size from nothing''')
	}
	
	protected dispatch def ElementSizeInferenceResult doInferFromType(EObject context, ProdType type) {
		// it's a struct, let's build our children, but mark the type first
		return PreventRecursion.preventRecursion(this.class.simpleName -> type, [
			val result = new ValidElementSizeInferenceResult(context, type, 1);
			result.children.addAll(type.typeArguments.tail.map[x|
				inferFromType(context, x)
			]);
			return result;
		], [|
			return newInvalidResult(context, '''Type "«type.name»" is recursive. Cannot infer size.''')
		]);
	}
	
	protected dispatch def ElementSizeInferenceResult doInferFromType(EObject context, SumType type) {
		return PreventRecursion.preventRecursion(this.class.simpleName -> type, [
			val childs = type.typeArguments.tail.map[
				doInferFromType(context, it)
			];
			val result = if(childs.filter(InvalidElementSizeInferenceResult).empty) {
				 new ValidElementSizeInferenceResult(context, type, 1);
			} else {
				val renamer = new NicerTypeVariableNamesForErrorMessages();
				new InvalidElementSizeInferenceResult(context, type, '''Cannot infer size of ""«context.class.simpleName»" of type"«type.modifyNames(renamer)»".''');
			}
							
			result.children += childs;
				
			return result;
		], [|
			return newInvalidResult(context, '''Type "«type.name»" is recursive. Cannot infer size.''')
		]);
	}
	
	/**
	 * Produces a valid size inference of the root object. This method assumes that the type
	 * we're reporting a multiple of (size parameter) is the result of typeInferer.infer(root). 
	 */
	protected def newValidResult(EObject root, long size) {
		val type = BaseUtils.getType(root);
		return new ValidElementSizeInferenceResult(root, type, size);
	}
	
	/**
	 * Produces an invalid size inference of the root object. This method assumes that the type
	 * we're reporting a multiple of (size parameter) is the result of typeInferer.infer(root). 
	 */
	protected def newInvalidResult(EObject root, String message) {
		val type = BaseUtils.getType(root);
		return new InvalidElementSizeInferenceResult(root, type, message);
	}
	
}

@FinalFieldsConstructor
class Combination implements ElementSizeInferrer {
	final ElementSizeInferrer i1;
	final ElementSizeInferrer i2;		
					
	override infer(ConstraintSystem system, Substitution sub, Resource r, EObject obj, AbstractType type) {
		val r1 = i1.infer(system, sub, r, obj, type);
		if(r1.present) {
			val r2 = i2.infer(system, sub, r, obj, type);
			if(r2.present) {
				// neither can handle this right now. Which pair do we return?
				// In theory both should return the same pair, but this might change.
				return r1;
			}
			else {
				return r2;
			}
		}
		else {
			return r1;
		}
	}
	
	override unbindSize(ConstraintSystem system, AbstractType t) {
		return i2.unbindSize(system, i1.unbindSize(system, t));
	}
	
	override setDelegate(ElementSizeInferrer delegate) {
	}
	
}

/**
 * The inference result of the ElementSizeInferrer
 */
abstract class ElementSizeInferenceResult {
	val EObject root;
	val AbstractType typeOf;
	val List<ElementSizeInferenceResult> children;
	
	def ElementSizeInferenceResult orElse(ElementSizeInferenceResult esir){
		return orElse([| esir]);
	}
	abstract def ElementSizeInferenceResult orElse(() => ElementSizeInferenceResult esirProvider);
	
	/**
	 * Creates a new valid inference result for an element, its type and the
	 * required element count.
	 */
	protected new(EObject root, AbstractType typeOf) {
		this.root = root;
		this.typeOf = typeOf;
		this.children = new LinkedList<ElementSizeInferenceResult>();
	}
	
	abstract def ElementSizeInferenceResult replaceRoot(EObject root);
	
	/**
	 * Checks if this size inference and its children are valid/complete.
	 */
	def boolean isValid() {
		return invalidSelfOrChildren.empty;
	}
	
	/**
	 * Returns true if this particular result node is valid.
	 */
	abstract def boolean isSelfValid();
	
	/**
	 * Returns a list of invalid/incomplete inference nodes which can be used for validation
	 * and user feedback.
	 */
	def Iterable<InvalidElementSizeInferenceResult> getInvalidSelfOrChildren() {
		return (if(isSelfValid) #[] else #[this as InvalidElementSizeInferenceResult]) + children.map[x | x.invalidSelfOrChildren ].flatten;
	}
	
	/**
	 * Returns a list of valid/complete inference nodes.
	 */
	def Iterable<ValidElementSizeInferenceResult> getValidSelfOrChildren() {
		return (if(isSelfValid) #[this as ValidElementSizeInferenceResult] else #[]) + children.map[x | x.validSelfOrChildren ].flatten;
	}
	
	/**
	 * The root element this size inference was made from.
	 */
	def EObject getRoot() {
		return root;
	}
	
	/**
	 * The data type we require elements of.
	 */
	def AbstractType getTypeOf() {
		return typeOf;
	}
	
	/**
	 * Any children we require as part of the type (i.e. through type parameters or struct members).
	 */
	def List<ElementSizeInferenceResult> getChildren() {
		return children;
	}
		
	override toString() {
		var result = if(typeOf instanceof TypeReferenceSpecifier) {
			typeOf.type.name;
		} else {
			""
		}
		result += ' {' + children.map[x | x.toString ].join(', ') + '}';
		return result;
	}
	
}

class ValidElementSizeInferenceResult extends ElementSizeInferenceResult {
	
	val long elementCount;
	
	new(EObject root, AbstractType typeOf, long elementCount) {
		super(root, typeOf);
		this.elementCount = elementCount;
	}
	
	/**
	 * The number of elements of this type we require.
	 */
	def long getElementCount() {
		return elementCount;
	}
	
	override isSelfValid() {
		return true;
	}
		
	override toString() {
		var result = typeOf?.toString;
		result += '::' + elementCount;
		if(!children.empty) {
			result += 'of{' + children.map[x | x.toString ].join(', ') + '}';			
		}
		return result;
	}
		
	override orElse(() => ElementSizeInferenceResult esirProvider) {
		return this;
	}
	
	override replaceRoot(EObject root) {
		val result = new ValidElementSizeInferenceResult(root, this.typeOf, this.elementCount);
		result.children += children;
		return result;
	}
	
}

class InvalidElementSizeInferenceResult extends ElementSizeInferenceResult {
	
	val String message;
	
	new(EObject root, AbstractType typeOf, String message) {
		super(root, typeOf);
		this.message = message;
	}
	
	def String getMessage() {
		return message;
	}
	
	override isSelfValid() {
		return false;
	}
	
	override toString() {
		return "INVALID:" + message + "@" + super.toString();
	}
	
	override orElse(() => ElementSizeInferenceResult esirProvider) {
		var esir = esirProvider?.apply();
		if(esir === null) {
			return this;
		}
		if(esir instanceof InvalidElementSizeInferenceResult) {
			esir = new InvalidElementSizeInferenceResult(esir.root, esir.typeOf, message + "\n" + esir.message);
		}
		return esir;
	}
	
	override replaceRoot(EObject root) {
		val result = new InvalidElementSizeInferenceResult(root, this.typeOf, this.message);
		result.children += children;
		return result;
	}
	
}
