package de.oehme.xtend.contrib

import com.google.common.cache.CacheBuilder
import com.google.common.cache.CacheLoader
import com.google.common.cache.LoadingCache
import com.google.common.util.concurrent.ExecutionError
import com.google.common.util.concurrent.UncheckedExecutionException
import de.oehme.xtend.contrib.macro.CommonTransformations
import java.lang.annotation.ElementType
import java.lang.annotation.Retention
import java.lang.annotation.RetentionPolicy
import java.lang.annotation.Target
import java.util.Arrays
import java.util.List
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import org.eclipse.xtend.lib.macro.Active
import org.eclipse.xtend.lib.macro.TransformationContext
import org.eclipse.xtend.lib.macro.TransformationParticipant
import org.eclipse.xtend.lib.macro.declaration.MethodDeclaration
import org.eclipse.xtend.lib.macro.declaration.MutableMethodDeclaration
import org.eclipse.xtend.lib.macro.declaration.ParameterDeclaration
import org.eclipse.xtend.lib.macro.declaration.TypeReference
import org.eclipse.xtend2.lib.StringConcatenationClient

/**
 * Caches invocations of a method. When the method is called multiple times with the same parameters, a cached result will be returned.
 * Useful for expensive calculations or recursive algorithms.
 * <br>
 * The method must guarantee the following conditions:
 * <ul>
 * 	<li>The method's parameters have meaningful equals/hashcode implementations.</li>
 * 	<li>The result of the method only depends on the parameters or immutable internal state</li>
 * 	<li>The method is referentially transparent (has no externally visible side effects)</li>
 * </ul>
 */
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
@Active(CachedProcessor)
annotation Cached {
	int maximumSize = 0
	int expireAfterWrite = 0
	int expireAfterAccess = 0
	TimeUnit timeUnit = TimeUnit.NANOSECONDS
}

class CachedProcessor implements TransformationParticipant<MutableMethodDeclaration> {

	/**
	 * This allows you to get the name of the cache field that will be generated for a cached method. 
	 * This way you can write your own active annotations that add additional features for cached methods.
	 */
	static def String cacheFieldName(MethodDeclaration method) {
		'''_cache_«method.simpleName»«IF !method.parameters.empty»_«method.parameters.join("_")[fieldFriendlyName]»«ENDIF»'''
	}

	private def static fieldFriendlyName(ParameterDeclaration it) {
		type.type.qualifiedName.replaceAll("\\.", "_")
	}

	override doTransform(List<? extends MutableMethodDeclaration> methods, extension TransformationContext context) {
		methods.forEach [
			switch (parameters.size) {
				case 0: new ParamterlessMethodMemoizer(it, context).generate
				case 1: new SingleParameterMethodMemoizer(it, context).generate
				default: new MultipleParameterMethodMemoizer(it, context).generate
			}
		]
	}
}

abstract class MethodMemoizer {
	protected val extension TransformationContext context
	protected val extension CommonTransformations transformations
	protected val MutableMethodDeclaration method

	new(MutableMethodDeclaration method, TransformationContext context) {
		this.method = method
		this.context = context
		this.transformations = new CommonTransformations(context)
	}

	def final generate() {
		method => [
			if (returnType.inferred) {
				addError("Please explicitly specify the return type")
				return
			}
			returnType = returnType.wrapperIfPrimitive
			addIndirection(initMethodName, cacheCall)
			declaringType => [
				addField(cacheFieldName) [
					static = method.static
					transient = true
					type = cacheFieldType
					initializer = cacheFieldInit
				]
			]
		]
	}

	def protected final String initMethodName() '''«method.simpleName»_init'''

	def protected final String cacheFieldName() {
		CachedProcessor.cacheFieldName(method)
	}

	def protected StringConcatenationClient cacheCall()

	def protected TypeReference cacheFieldType()

	def protected StringConcatenationClient cacheFieldInit()
}

/**
 * Uses double null check synchronization for multithreaded correctness and performance
 */
class ParamterlessMethodMemoizer extends MethodMemoizer {

	new(MutableMethodDeclaration method, TransformationContext context) {
		super(method, context)
	}

	override protected cacheCall() '''
		if («cacheFieldName» == null) {
			synchronized(«lock») {
				if («cacheFieldName» == null) {
					«cacheFieldName» = «initMethodName»();
				}
			}
		}
		return «cacheFieldName»;
	'''

	override protected cacheFieldType() {
		method.returnType
	}

	override protected cacheFieldInit() '''null'''

	def lock() {
		if (method.static) '''«method.declaringType.simpleName».class''' else "this"
	}
}

/**
 * Uses Guava's LoadingCache to store the return value for each combination of parameters
 */
abstract class ParametrizedMethodMemoizer extends MethodMemoizer {
	new(MutableMethodDeclaration method, TransformationContext context) {
		super(method, context)
	}

	override protected final cacheFieldInit() '''
		«CacheBuilder».newBuilder()
		«IF maximumSize > 0»
			.maximumSize(«maximumSize»)
		«ENDIF»
		«IF expireAfterWrite > 0»
			.expireAfterWrite(«expireAfterWrite», «TimeUnit».«timeUnit»)
		«ENDIF»
		«IF expireAfterAccess > 0»
			.expireAfterAccess(«expireAfterAccess», «TimeUnit».«timeUnit»)
		«ENDIF»
		.build(new «CacheLoader»<«cacheKeyType», «method.returnType»>() {
			@Override
			public «method.returnType» load(«cacheKeyType» key) throws Exception {
				return «initMethodName»(«cacheKeyToParameters»);
			}
		})
	'''

	override protected final cacheFieldType() {
		newTypeReference(LoadingCache, cacheKeyType, method.returnType)
	}

	override protected final cacheCall() '''
		try {
			return «cacheFieldName».get(«parametersToCacheKey()»);
		} catch (Throwable e) {
			if (e instanceof «ExecutionException»
				|| e instanceof «UncheckedExecutionException»
				|| e instanceof «ExecutionError») {
				Throwable cause = e.getCause();
				throw «Exceptions».sneakyThrow(cause);
			} else {
				throw «Exceptions».sneakyThrow(e);
			}
		}
	'''

	protected def final maximumSize() {
		cacheAnnotation.getIntValue("maximumSize")
	}

	protected def final expireAfterWrite() {
		cacheAnnotation.getIntValue("expireAfterWrite")
	}

	protected def final expireAfterAccess() {
		cacheAnnotation.getIntValue("expireAfterAccess")
	}

	protected def final timeUnit() {
		cacheAnnotation.getEnumValue("timeUnit").simpleName
	}

	protected def final cacheAnnotation() {
		method.findAnnotation(findTypeGlobally(Cached))
	}

	def protected TypeReference cacheKeyType()

	def protected StringConcatenationClient parametersToCacheKey()

	def protected StringConcatenationClient cacheKeyToParameters()
}

class SingleParameterMethodMemoizer extends ParametrizedMethodMemoizer {
	new(MutableMethodDeclaration method, TransformationContext context) {
		super(method, context)
	}

	override protected cacheKeyToParameters() '''key'''

	override protected parametersToCacheKey() '''«parameter.simpleName»'''

	override protected cacheKeyType() {
		parameter.type.wrapperIfPrimitive
	}

	def private parameter() {
		method.parameters.head
	}
}

class MultipleParameterMethodMemoizer extends ParametrizedMethodMemoizer {
	new(MutableMethodDeclaration method, TransformationContext context) {
		super(method, context)
	}

	override protected cacheKeyToParameters() '''«FOR p : method.parameters SEPARATOR ","»(«p.type.wrapperIfPrimitive») key.get(«method.parameters.toList.indexOf(p)»)«ENDFOR»'''

	override protected parametersToCacheKey() '''new «cacheKeyType»(«method.parameters.join(",")[simpleName]»)'''

	override protected cacheKeyType() {
		CacheKey.newTypeReference
	}
}

/**
 * This class is an implementation detail and not fit for general use.
 * It foregoes immutability for pure performance
 */
class CacheKey {
	val Object[] parameters

	new(Object... parameters) {
		this.parameters = parameters
	}

	def Object get(int index) {
		parameters.get(index)
	}

	override equals(Object obj) {
		if (obj instanceof CacheKey) {
			return Arrays.equals(parameters, obj.parameters)
		}
		false
	}

	override hashCode() {
		Arrays.hashCode(parameters)
	}
}
