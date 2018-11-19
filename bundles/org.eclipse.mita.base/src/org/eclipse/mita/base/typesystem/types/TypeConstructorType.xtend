package org.eclipse.mita.base.typesystem.types

import java.util.ArrayList
import java.util.List
import org.eclipse.emf.ecore.EObject
import org.eclipse.mita.base.types.validation.IValidationIssueAcceptor.ValidationIssue
import org.eclipse.mita.base.types.validation.IValidationIssueAcceptor.ValidationIssue.Severity
import org.eclipse.mita.base.typesystem.constraints.AbstractTypeConstraint
import org.eclipse.mita.base.typesystem.constraints.EqualityConstraint
import org.eclipse.mita.base.typesystem.solver.ConstraintSystem
import org.eclipse.mita.base.typesystem.solver.Substitution
import org.eclipse.xtend.lib.annotations.Accessors
import org.eclipse.xtend.lib.annotations.EqualsHashCode
import org.eclipse.xtend.lib.annotations.FinalFieldsConstructor

import static extension org.eclipse.mita.base.util.BaseUtils.force

import static extension org.eclipse.mita.base.util.BaseUtils.zip;

@FinalFieldsConstructor
@EqualsHashCode
@Accessors
class TypeConstructorType extends AbstractType {
	protected static Integer instanceCount = 0;
	protected val List<AbstractType> typeArguments;
	// transient makes EqualsHashCode ignore this
	protected final transient List<AbstractType> superTypes = new ArrayList();
	
	new(EObject origin, String name, Iterable<AbstractType> typeArguments, Iterable<AbstractType> superTypes) {
		this(origin, name, typeArguments.force);
		this.superTypes += superTypes;
		if(this.toString == "bar_args(foo(), f_60.0, f_67.0)") {
			print("")
		}
	}
	
	def AbstractTypeConstraint getVariance(int typeArgumentIdx, AbstractType tau, AbstractType sigma) {
		return new EqualityConstraint(tau, sigma, new ValidationIssue(Severity.ERROR, '''«tau» is not equal to «sigma»''', ""));
	}
	def void expand(ConstraintSystem system, Substitution s, TypeVariable tv) {
		val newTypeVars = typeArguments.map[ system.newTypeVariable(it.origin) as AbstractType ].force;
		val newCType = new TypeConstructorType(origin, name, newTypeVars, superTypes);
		s.add(tv, newCType);
	}
		
	override toString() {
		return '''«super.toString»«IF !typeArguments.empty»<«typeArguments.join(", ")»>«ENDIF»«IF !superTypes.empty» ⩽ «superTypes.map[it.name]»«ENDIF»'''
	}
	
	override getFreeVars() {
		return typeArguments.flatMap[it.freeVars];
	}
	
	override toGraphviz() {
		'''«FOR t: typeArguments»"«t»" -> "«this»"; "«this»" -> "«t»" «t.toGraphviz»«ENDFOR»''';
	}
		
	override map((AbstractType)=>AbstractType f) {
		val newTypeArgs = typeArguments.map[ it.map(f) ].force;
		if(typeArguments.zip(newTypeArgs).exists[it.key !== it.value]) {
			return new TypeConstructorType(origin, name, newTypeArgs, superTypes);
		}
		return this;
	}
	
}