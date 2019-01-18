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

package org.eclipse.mita.program.generator

import com.google.inject.Inject
import org.eclipse.emf.ecore.EObject
import org.eclipse.mita.base.expressions.AssignmentOperator
import org.eclipse.mita.base.typesystem.StdlibTypeRegistry
import org.eclipse.mita.base.typesystem.types.AbstractType
import org.eclipse.mita.program.NewInstanceExpression
import org.eclipse.mita.program.VariableDeclaration
import org.eclipse.mita.base.typesystem.infra.SubtypeChecker
import org.eclipse.mita.base.typesystem.infra.MitaBaseResource

/**
 * Interface for type generators.
 */
abstract class AbstractTypeGenerator implements IGenerator {

	@Inject SubtypeChecker subtypeChecker;

	@Inject
	protected TypeGenerator typeGenerator
	
	@Inject
	protected CodeFragmentProvider codeFragmentProvider
	
	/**
	 * Produces a code fragment with the actual type specifier
	 */
	def CodeFragment generateTypeSpecifier(AbstractType type, EObject context) {
		codeFragmentProvider.create('''«typeGenerator.code(type)»''')
	}
	
	/**
	 * Produces a variable declaration for a variable of a generated type
	 */
	def CodeFragment generateVariableDeclaration(AbstractType type, VariableDeclaration stmt) {
		codeFragmentProvider.create('''«typeGenerator.code(type)» «stmt.name»;''')
	}
	
	/**
	 * Produces a new instance of the type
	 */
	def CodeFragment generateNewInstance(AbstractType type, NewInstanceExpression expr);

	/**
	 * Checks if this type supports a particular expression within its type hierarchy
	 */
	def boolean checkExpressionSupport(AbstractType type, AssignmentOperator operator, AbstractType otherType) {
		val obj = type.origin ?: otherType.origin;
		val resource = obj.eResource;
		val cs = if(resource instanceof MitaBaseResource) resource.latestSolution.constraints;
		return operator == AssignmentOperator.ASSIGN && subtypeChecker.isSubType(cs, type.origin, otherType, type);
	}
	
	/**
	 * Produces code which implements an assignment operation. This function will only be executed if
	 * {@link #checkExpressionSupport) returned true for the corresponding types.
	 */
	def CodeFragment generateExpression(AbstractType type, EObject left, AssignmentOperator operator, EObject right) {
		return codeFragmentProvider.create('''«left» «operator.literal» «right»;''');
	}
	
	/**
	 * Produces header definitions. Called only once.
	 */
	def CodeFragment generateHeader() {
		return CodeFragment.EMPTY;
	}
	
	/**
	 * Produces header definitions, called per different instance of type arguments.
	 */
	def CodeFragment generateHeader(AbstractType type) {
		return CodeFragment.EMPTY;
	}
}