
import time
import random

from libcpp cimport bool
from libcpp.map cimport map as omap
from libcpp.pair cimport pair
from libcpp.vector cimport vector                                               
from libcpp.set cimport set as oset                                             
from libcpp.string cimport string   

from py_stringsimjoin.apply_rf.predicate import Predicate                       
from py_stringsimjoin.apply_rf.tokenizers cimport tokenize_without_materializing
from py_stringsimjoin.apply_rf.utils cimport compfnptr, str_simfnptr, \
  token_simfnptr, get_comp_type, get_comparison_function, get_sim_type, \
  get_token_sim_function, get_str_sim_function
from py_stringsimjoin.apply_rf.predicatecpp cimport Predicatecpp
from py_stringsimjoin.apply_rf.rule cimport Rule
from py_stringsimjoin.apply_rf.tree cimport Tree                                
from py_stringsimjoin.apply_rf.node cimport Node
from py_stringsimjoin.apply_rf.coverage cimport Coverage


# Sample a set of pairs from the candidate set of pairs
cdef pair[pair[vector[string], vector[string]], vector[int]] sample_pairs(
                   pair[vector[pair[int, int]], vector[int]]& candset_votes,
                                              const int& sample_size,  
                                              vector[string]& lstrings,
                                              vector[string]& rstrings):
    cdef double p = <double>sample_size / <double>candset_votes.second.size()                
    cdef vector[string] lsample, rsample
    cdef vector[int] sample_votes                                        
    cdef pair[int, int] entry
    cdef int i                                              
    for i in xrange(candset_votes.second.size()):                                                       
        if random.random() <= p:
            entry = candset_votes.first[i]                                                
            lsample.push_back(lstrings[entry.first])                         
            rsample.push_back(rstrings[entry.second])
            sample_votes.push_back(candset_votes.second[i])
                         
    print 'sample size : ', lsample.size()                                      
    return pair[pair[vector[string], vector[string]], vector[int]](pair[vector[string], vector[string]](lsample, rsample), sample_votes)  


cdef void compute_predicate_cost_and_coverage(vector[string]& lstrings, 
                                              vector[string]& rstrings, 
                                              vector[Tree]& trees, 
                                              omap[string, Coverage]& coverage, 
                                              omap[int, Coverage]& tree_cov, int n_jobs):
    cdef omap[string, vector[double]] features
    cdef omap[string, double] cost    
    cdef int sample_size = lstrings.size()
    cdef omap[string, pair[string, string]] feature_info
    cdef omap[string, vector[vector[int]]] ltokens, rtokens
    cdef Tree tree
    cdef Rule rule
    cdef Predicatecpp predicate
    cdef oset[string] tok_types
    cdef double sim_score, start_time, end_time
    cdef token_simfnptr token_sim_fn
    cdef str_simfnptr str_sim_fn  
    cdef compfnptr comp_fn
    cdef omap[string, vector[double]] feature_values 

    for tree in trees:
        for rule in tree.rules:
            for predicate in rule.predicates:
                feature_info[predicate.feat_name] = pair[string, string](predicate.sim_measure_type, predicate.tokenizer_type)
                if predicate.is_tok_sim_measure:
                    tok_types.insert(predicate.tokenizer_type)
    print 't1'
    for tok_type in tok_types:
        ltokens[tok_type] = vector[vector[int]]()
        rtokens[tok_type] = vector[vector[int]]()                               
        tokenize_without_materializing(lstrings, rstrings, tok_type, 
                                       ltokens[tok_type], rtokens[tok_type], n_jobs) 
        
    print 't2'
    for feature in feature_info:
        if feature.second.second.compare('none') == 0:
            str_sim_fn = get_str_sim_function(get_sim_type(feature.second.first))       
            cost[feature.first] = 0.0                                           
            for i in xrange(sample_size):                                       
                start_time = time.time()                                        
                sim_score = str_sim_fn(lstrings[i], rstrings[i])           
                end_time = time.time()                                          
                cost[feature.first] += (end_time - start_time)                  
                feature_values[feature.first].push_back(sim_score)              
            cost[feature.first] /= sample_size   
        else: 
            token_sim_fn = get_token_sim_function(get_sim_type(feature.second.first))
            cost[feature.first] = 0.0
            for i in xrange(sample_size):
                start_time = time.time()
                sim_score = token_sim_fn(ltokens[feature.second.second][i], 
                                         rtokens[feature.second.second][i])
                end_time = time.time()
                cost[feature.first] += (end_time - start_time)
                feature_values[feature.first].push_back(sim_score)
            cost[feature.first] /= sample_size
#            if (feature.second.first.compare('OVERLAP_COEFFICIENT') == 0 and
#                feature.second.second.compare('qg2') == 0):
#                cost[feature.first] = cost[feature.first] * 10
     #   print feature.first, cost[feature.first]
    print 't3'
    cdef int max_size = 0
    cdef omap[string, vector[bool]] cov
    cdef int x, y, z
    cdef Coverage c1                                                            
    for x in xrange(trees.size()):                                              
        for y in xrange(trees[x].rules.size()):                                 
            c1.reset()                                                          
            for z in xrange(trees[x].rules[y].predicates.size()):               
                predicate = trees[x].rules[y].predicates[z]
                trees[x].rules[y].predicates[z].set_cost(cost[predicate.feat_name])
                if cov[predicate.pred_name].size() == 0:                        
                    comp_fn = get_comparison_function(get_comp_type(predicate.comp_op))
                    for i in xrange(sample_size):                               
                        cov[predicate.pred_name].push_back(comp_fn(feature_values[predicate.feat_name][i], predicate.threshold))
                    if cov[predicate.pred_name].size() > max_size:              
                        max_size = cov[predicate.pred_name].size()              
                    coverage[predicate.pred_name] = Coverage(cov[predicate.pred_name])
                if z == 0:                                                      
                    c1.or_coverage(coverage[predicate.pred_name])               
                else:                                                           
                    c1.and_coverage(coverage[predicate.pred_name])              
            tree_cov[x].or_coverage(c1) 

#    cdef Node plan
#    cdef double cost1, sel1
#    for x in xrange(trees.size()):
#        plan = gen_plan_for_tree(trees[x], coverage, sample_size, False)
#        cost1 = compute_plan_cost(plan, coverage, sample_size)
#        sel1 = <double>tree_cov[x].sum()/ <double>sample_size
#        print 'tree ', x, ' , cost : ', cost1, ' , sel : ', sel1


# Generate execution plans for executing the remaining (n/2 - 1) trees
# This function would find an optimal ordering of the remaining trees and return
# a plan for each of the (n/2 - 1) trees in that order.
cdef vector[Node] generate_ex_plan_for_stage2(pair[vector[pair[int, int]], vector[int]]& candset_votes,
                                              vector[string]& lstrings, 
                                              vector[string]& rstrings, 
                                              vector[Tree]& trees,
                                              int orig_sample_size, int n_jobs, bool push_flag, bool random_order):
    cdef pair[pair[vector[string], vector[string]], vector[int]] sample = sample_pairs(
                                                                    candset_votes,
                                                                    orig_sample_size,
                                                                    lstrings,
                                                                    rstrings)
    cdef omap[string, Coverage] coverage
    cdef omap[string, vector[double]] features                                  
    cdef omap[string, double] cost                                              
    cdef int i, sample_size = sample.second.size()                                      
    cdef omap[string, pair[string, string]] feature_info                        
    cdef omap[string, vector[vector[int]]] ltokens, rtokens                     
    cdef Tree tree                                                              
    cdef Rule rule                                                              
    cdef Predicatecpp predicate                                                 
    cdef oset[string] tok_types                                                 
    cdef double sim_score, start_time, end_time                                 
    cdef token_simfnptr token_sim_fn                                            
    cdef str_simfnptr str_sim_fn   
    cdef compfnptr comp_fn                                                      
    cdef omap[string, vector[double]] feature_values                            
                                                                                
    for tree in trees:                                                          
        for rule in tree.rules:                                                 
            for predicate in rule.predicates:                                   
                feature_info[predicate.feat_name] = pair[string, string](predicate.sim_measure_type, predicate.tokenizer_type)
                if predicate.is_tok_sim_measure:
                    tok_types.insert(predicate.tokenizer_type)                      
    print 't1'                                                                  
    for tok_type in tok_types:                                                  
        ltokens[tok_type] = vector[vector[int]]()                               
        rtokens[tok_type] = vector[vector[int]]()                               
        tokenize_without_materializing(sample.first.first, sample.first.second, tok_type,            
                                       ltokens[tok_type], rtokens[tok_type], n_jobs)    
                                                                                
    print 't2'                                                                  
    for feature in feature_info:
        print feature.first, feature.second.first, feature.second.second                                                
        if feature.second.second.compare('none') == 0:                          
            str_sim_fn = get_str_sim_function(get_sim_type(feature.second.first))
            cost[feature.first] = 0.0                                           
            for i in xrange(sample_size):                                       
                start_time = time.time()                                        
                sim_score = str_sim_fn(sample.first.first[i], sample.first.second[i])                
                end_time = time.time()                                          
                cost[feature.first] += (end_time - start_time)                  
                feature_values[feature.first].push_back(sim_score)              
            cost[feature.first] /= sample_size                                  
        else:                                                                   
            token_sim_fn = get_token_sim_function(get_sim_type(feature.second.first))
            cost[feature.first] = 0.0                                           
            for i in xrange(sample_size):                                       
                start_time = time.time()                                        
                sim_score = token_sim_fn(ltokens[feature.second.second][i],     
                                         rtokens[feature.second.second][i])     
                end_time = time.time()                                          
                cost[feature.first] += (end_time - start_time)                  
                feature_values[feature.first].push_back(sim_score)              
            cost[feature.first] /= sample_size  
    print 't3'                                                                  
    cdef int max_size = 0                                                       
    cdef omap[string, vector[bool]] cov                                         
    cdef int x, y, z                                                            
    cdef omap[int, Coverage] tree_cov
    cdef Coverage c1
    for x in xrange(trees.size()):                                          
        for y in xrange(trees[x].rules.size()):
            c1.reset()                                 
            for z in xrange(trees[x].rules[y].predicates.size()):               
                predicate = trees[x].rules[y].predicates[z]                     
                trees[x].rules[y].predicates[z].set_cost(cost[predicate.feat_name])
                if cov[predicate.pred_name].size() == 0:                        
                    comp_fn = get_comparison_function(get_comp_type(predicate.comp_op))
                    for i in xrange(sample_size):                               
                        cov[predicate.pred_name].push_back(comp_fn(feature_values[predicate.feat_name][i], predicate.threshold))
                    if cov[predicate.pred_name].size() > max_size:              
                        max_size = cov[predicate.pred_name].size()              
                    coverage[predicate.pred_name] = Coverage(cov[predicate.pred_name])
                if z == 0:
                    c1.or_coverage(coverage[predicate.pred_name])
                else:
                    c1.and_coverage(coverage[predicate.pred_name])                           
            tree_cov[x].or_coverage(c1)
    print 't4'
    cdef vector[double] tree_costs
    cdef vector[Node] tree_plans
    cdef Node plan

    for i in xrange(trees.size()):
#        print i
        plan = gen_plan_for_tree(trees[i], coverage, sample_size, push_flag, random_order)
        tree_plans.push_back(plan)
        tree_costs.push_back(compute_plan_cost(plan, coverage, sample_size))

    print 't5'
#    cdef vector[int] opt_tree_seq = get_optimal_tree_seq(tree_costs, tree_cov, sample_size) 
    cdef vector[int] opt_tree_seq = get_optimal_tree_seq_v1(tree_costs, tree_cov, sample_size, sample.second)
# cit worst    opt_tree_seq = [3, 0, 1, 2]
#    opt_tree_seq = [1, 2, 3, 0]
    cdef vector[Node] ordered_plans

    for i in opt_tree_seq:
        print i
        ordered_plans.push_back(tree_plans[i])

    return ordered_plans 

cdef Node generate_ex_plan_for_stage2_test(pair[vector[pair[int, int]], vector[int]]& candset_votes,
                                              vector[string]& lstrings,
                                              vector[string]& rstrings,
                                              vector[Tree]& trees,
                                              int orig_sample_size, int n_jobs, bool push_flag):
    cdef pair[pair[vector[string], vector[string]], vector[int]] sample = sample_pairs(
                                                                    candset_votes,
                                                                    orig_sample_size,
                                                                    lstrings,
                                                                    rstrings)
    cdef omap[string, Coverage] coverage
    cdef omap[string, vector[double]] features
    cdef omap[string, double] cost
    cdef int i, sample_size = sample.second.size()
    cdef omap[string, pair[string, string]] feature_info
    cdef omap[string, vector[vector[int]]] ltokens, rtokens
    cdef Tree tree
    cdef Rule rule
    cdef Predicatecpp predicate
    cdef oset[string] tok_types
    cdef double sim_score, start_time, end_time
    cdef token_simfnptr token_sim_fn
    cdef str_simfnptr str_sim_fn
    cdef compfnptr comp_fn
    cdef omap[string, vector[double]] feature_values

    for tree in trees:
        for rule in tree.rules:
            for predicate in rule.predicates:
                feature_info[predicate.feat_name] = pair[string, string](predicate.sim_measure_type, predicate.tokenizer_type)
                if predicate.is_tok_sim_measure:
                    tok_types.insert(predicate.tokenizer_type)
    print 't1'
    for tok_type in tok_types:
        ltokens[tok_type] = vector[vector[int]]()
        rtokens[tok_type] = vector[vector[int]]()
        tokenize_without_materializing(sample.first.first, sample.first.second, tok_type,
                                       ltokens[tok_type], rtokens[tok_type], n_jobs)

    print 't2'
    for feature in feature_info:
        print feature.first, feature.second.first, feature.second.second
        if feature.second.second.compare('none') == 0:
            str_sim_fn = get_str_sim_function(get_sim_type(feature.second.first))
            cost[feature.first] = 0.0
            for i in xrange(sample_size):
                start_time = time.time()
                sim_score = str_sim_fn(sample.first.first[i], sample.first.second[i])
                end_time = time.time()
                cost[feature.first] += (end_time - start_time)
                feature_values[feature.first].push_back(sim_score)
            cost[feature.first] /= sample_size
        else:
            token_sim_fn = get_token_sim_function(get_sim_type(feature.second.first))
            cost[feature.first] = 0.0
            for i in xrange(sample_size):
                start_time = time.time()
                sim_score = token_sim_fn(ltokens[feature.second.second][i],
                                         rtokens[feature.second.second][i])
                end_time = time.time()
                cost[feature.first] += (end_time - start_time)
                feature_values[feature.first].push_back(sim_score)
            cost[feature.first] /= sample_size
    print 't3'
    cdef int max_size = 0
    cdef omap[string, vector[bool]] cov
    cdef int x, y, z
    cdef omap[int, Coverage] tree_cov
    cdef Coverage c1
    for x in xrange(trees.size()):
        for y in xrange(trees[x].rules.size()):
            c1.reset()
            for z in xrange(trees[x].rules[y].predicates.size()):
                predicate = trees[x].rules[y].predicates[z]
                trees[x].rules[y].predicates[z].set_cost(cost[predicate.feat_name])
                if cov[predicate.pred_name].size() == 0:
                    comp_fn = get_comparison_function(get_comp_type(predicate.comp_op))
                    for i in xrange(sample_size):
                        cov[predicate.pred_name].push_back(comp_fn(feature_values[predicate.feat_name][i], predicate.threshold))
                    if cov[predicate.pred_name].size() > max_size:
                        max_size = cov[predicate.pred_name].size()
                    coverage[predicate.pred_name] = Coverage(cov[predicate.pred_name])
                if z == 0:
                    c1.or_coverage(coverage[predicate.pred_name])
                else:
                    c1.and_coverage(coverage[predicate.pred_name])
            tree_cov[x].or_coverage(c1)
    print 't4'
    cdef Node plan
    plan = gen_plan_for_trees_stage2(trees, coverage, sample_size, push_flag)
    return plan

cdef vector[int] get_random_filter_order(vector[int] optimal_seq):
    cdef vector[int] random_order
    cdef int n = optimal_seq.size(), i, j
    used = [False for _ in xrange(n)]    
    i = 0
    while i < n:
        j = random.randint(0, n-1)
        if not used[j]:
            random_order.push_back(optimal_seq[j])
            used[j] = True
            i += 1
    return random_order

cdef Node gen_plan_for_tree(Tree& tree, omap[string, Coverage]& coverage, 
                            const int& sample_size, bool push_flag, bool random_order):
    cdef Rule rule                                                              
    cdef vector[int] optimal_seq                                                
    cdef vector[Node] nodes, plans                                                     
    cdef Node root, new_node, curr_node                                         
    cdef string node_type                                                       
    cdef int i                                          

    for rule in tree.rules:                                                 
        nodes = vector[Node]()                                             
        
        optimal_seq = get_optimal_filter_seq(rule.predicates, coverage, sample_size)
        if random_order:
            optimal_seq = get_random_filter_order(optimal_seq)
 
        node_type = "ROOT"                                                  
        nodes.push_back(Node(node_type))                                    
                                                                                
        for i in optimal_seq:                                               
            node_type = "FILTER"                                                                                
            new_node = Node(node_type)                                      
            new_node.predicates.push_back(rule.predicates[i])               
            nodes.push_back(new_node)                                       
                                                                                
        node_type = "OUTPUT"                                                
        new_node = Node(node_type)                                          
        nodes.push_back(new_node)                                           
        print 'n ', nodes.size()                                            
        for i in xrange(nodes.size() - 2, -1, -1):                          
            nodes[i].add_child(nodes[i+1])                                  
        plans.push_back(nodes[0])
    
    cdef vector[Node] pushed_plans
    cdef Node combined_plan                                        

    if push_flag:
        push_filters(plans, pushed_plans)

        for i in range(pushed_plans.size()):                                    
            if i == 0:                                                          
                combined_plan = pushed_plans[i]                                 
            else:                                                               
                combined_plan = merge_plans_stage2(combined_plan, pushed_plans[i])
        
    else:
        for i in range(plans.size()):                                    
            if i == 0:                                                          
                combined_plan = plans[i]                                 
            else:                                                               
                combined_plan = merge_plans_stage2(combined_plan, plans[i])    

    return combined_plan    

cdef Node gen_plan_for_trees_stage2(vector[Tree]& trees, omap[string, Coverage]& coverage,
                            const int& sample_size, bool push_flag):
    cdef Rule rule
    cdef vector[int] optimal_seq
    cdef vector[Node] nodes, plans
    cdef Node root, new_node, curr_node
    cdef string node_type
    cdef Tree tree
    cdef int i

    for tree in trees:
        for rule in tree.rules:
            nodes = vector[Node]()
 #       print 'test1' 
            optimal_seq = get_optimal_filter_seq(rule.predicates, coverage, sample_size)
#        print 'test2'
            node_type = "ROOT"
            nodes.push_back(Node(node_type))

            for i in optimal_seq:
                node_type = "FILTER"
                new_node = Node(node_type)
                new_node.predicates.push_back(rule.predicates[i])
                nodes.push_back(new_node)

            node_type = "OUTPUT"
            new_node = Node(node_type)
            new_node.set_tree_id(tree.tree_id)
            nodes.push_back(new_node)
#        print 'n ', nodes.size()                                            
            for i in xrange(nodes.size() - 2, -1, -1):
                nodes[i].add_child(nodes[i+1])
            plans.push_back(nodes[0])

    cdef vector[Node] pushed_plans
    cdef Node combined_plan

    if push_flag:
        push_filters(plans, pushed_plans)

        for i in range(pushed_plans.size()):
            if i == 0:
                combined_plan = pushed_plans[i]
            else:
                combined_plan = merge_plans_stage2(combined_plan, pushed_plans[i])
    else:
        for i in range(plans.size()):
            if i == 0:
                combined_plan = plans[i]
            else:
                combined_plan = merge_plans_stage2(combined_plan, plans[i])

    return combined_plan


cdef double compute_plan_cost(Node& plan, omap[string, Coverage]& coverage, const int& sample_size):
    cdef vector[bool] bool_vector
    cdef Coverage cov
    cdef int i
    for i in xrange(coverage[plan.children[0].predicates[0].pred_name].size):
        bool_vector.push_back(True)
    cov = Coverage(bool_vector)
    cdef double cost = 0.0
    cdef Node child_node
    for child_node in plan.children:
        cost += compute_subtree_cost(child_node, cov, coverage, sample_size)
    return cost

cdef double compute_subtree_cost(Node plan, Coverage curr_cov, omap[string, Coverage]& coverage, const int& sample_size):
    if plan.node_type.compare("OUTPUT") == 0:
        return 0.0

    cdef double child_cost = 0.0
    cdef Node child_node
    cdef Coverage cov
    cov.or_coverage(curr_cov)
    cov.and_coverage(coverage[plan.predicates[0].pred_name])
    for child_node in plan.children:
        child_cost += compute_subtree_cost(child_node, cov, coverage, sample_size)
    
    cdef double sel = <double>curr_cov.sum() / <double>sample_size                                

    if plan.node_type.compare("SELECT") == 0:
        return child_cost

    return sel * plan.predicates[0].cost + child_cost
                                               
cdef Node merge_plans_stage2(Node plan1, Node plan2):                                  
    cdef Node new_node, plan2_node = plan2.children[0]                                    
    cdef Predicatecpp pred1, pred2                                              
    cdef string node_type = "SELECT"                                            
    pred2 = plan2_node.predicates[0]                                            
    cdef int i=0                                                                  
                                                                                
    while i < plan1.children.size():                                            
#        print 'sib : ', plan1.children[i].node_type                             
        if plan1.children[i].predicates[0].feat_name.compare(pred2.feat_name) == 0:         
            break                                                               
        i += 1                                                                  
                                                                                
    if i == plan1.children.size():                                              
        plan1.add_child(plan2.children[0])                                      
        return plan1                                                            
                                                                                
#    print 't1', plan2_node.node_type                                            
    pred1 = plan1.children[i].predicates[0]
    cdef vector[Predicatecpp] preds
    if plan1.children[i].node_type.compare("FEATURE") == 0:
        node_type = "SELECT"
        plan2_node.set_node_type(node_type)                                                                      
        plan1.children[i].add_child(plan2_node)                                 
    elif plan1.children[i].node_type.compare("FILTER") == 0:
        node_type = "SELECT"
        plan2_node.set_node_type(node_type)

        plan1.children[i].set_node_type(node_type)

        preds.push_back(plan1.children[i].predicates[0])
        new_node = Node(preds, "FEATURE")
        new_node.add_child(plan1.children[i])
        new_node.add_child(plan2_node)

        plan1.remove_child(plan1.children[i])
        plan1.add_child(new_node)                                                                                 
    return plan1  

# Ordering a set of filter predicates
cdef vector[int] get_optimal_filter_seq(vector[Predicatecpp]& predicates,
                                        omap[string, Coverage]& coverage,
                                        const int sample_size):
    cdef vector[int] optimal_seq          
    cdef vector[bool] selected_predicates   
    cdef Coverage prev_coverage                                                 
    cdef int i, j = 0, n=predicates.size(), max_pred 
    cdef double max_score, pred_score                                           
    print 'num preds : ', n 
    for i in xrange(n):
        selected_predicates.push_back(False)
                                                                  
    for j in xrange(n):                                                                
        max_score = 0.0                                                          
        max_pred = -1                                                           
                                                                                
        for i in xrange(n):                                              
            if selected_predicates[i]:                                          
                continue                                                        

            if j == 0:
                pred_score = (1.0 - (coverage[predicates[i].pred_name].count / sample_size)) / predicates[i].cost
            else:                                                            
                pred_score = (1.0 - (prev_coverage.and_sum(coverage[predicates[i].pred_name]) / sample_size)) / predicates[i].cost

            #print pred_score, max_score                                         
                                                                                
            if pred_score > max_score or max_score == 0.0:                                          
                max_score = pred_score                                          
                max_pred = i                                                    
                                                                                
        optimal_seq.push_back(max_pred)                                         
        selected_predicates[max_pred] = True
                                           
        if j == 0:
            prev_coverage.or_coverage(coverage[predicates[max_pred].pred_name])         
        else:
            prev_coverage.and_coverage(coverage[predicates[max_pred].pred_name])    

    return optimal_seq

# Ordering a set of trees
cdef vector[int] get_optimal_tree_seq(vector[double] costs,       
                                      omap[int, Coverage]& coverage,       
                                      const int sample_size):                 
    cdef vector[int] optimal_seq                                                
    cdef vector[bool] selected_trees                                       
    cdef Coverage prev_coverage                                                 
    cdef int i, j = 0, n=costs.size(), max_tree                          
    cdef double max_score, tree_score                                           
                                                                                
    for i in xrange(n):                                                         
        selected_trees.push_back(False)                                          
                                                                                
    for j in xrange(n):                                                         
        max_score = 0.0                                                          
        max_tree = -1                                                           
                                                                                
        for i in xrange(n):                                                     
            if selected_trees[i]:                                          
                continue                                                        
                                                                                
            if j == 0:                                                          
                tree_score = (1.0 - (coverage[i].sum() / sample_size)) / costs[i]
            else:                                                               
                tree_score = (1.0 - (prev_coverage.and_sum(coverage[i]) / sample_size)) / costs[i]
                                                                                
#            print tree_score, max_score                                         
                                                                                
            if tree_score > max_score or max_score == 0.0:                                          
                max_score = tree_score                                          
                max_tree = i                                                    
                                                                                
        optimal_seq.push_back(max_tree)                                         
        selected_trees[max_tree] = True                                    
        if j == 0:                                                              
            prev_coverage.or_coverage(coverage[max_tree]) 
        else:                                                                   
            prev_coverage.and_coverage(coverage[max_tree])
                                                                                
    return optimal_seq 

cdef vector[int] get_optimal_tree_seq_v1(vector[double]& costs,
                                      omap[int, Coverage]& coverage,
                                      const int sample_size,
                                      vector[int]& votes):
    cdef vector[int] optimal_seq, curr_votes
    cdef vector[bool] selected_trees
    cdef int i, j = 0, n=costs.size(), max_tree, k, d
    cdef double max_score, tree_score

    for i in xrange(n):
        selected_trees.push_back(False)

    for i in xrange(sample_size):
        curr_votes.push_back(votes[i])

    for j in xrange(n):
        max_score = 0.0
        max_tree = -1

        for i in xrange(n):
            if selected_trees[i]:
                continue

            d = 0
            
            for k in xrange(sample_size):
                if curr_votes[k] != -1:
                    if coverage[i].index(k):
                        if curr_votes[k] + 1 >= 5:
                            d += 1
                    else:
                        if curr_votes[k] + n - j - 1 < 5:
                            d += 1
                
            tree_score = (<double>d / <double>sample_size) / costs[i]

            if tree_score > max_score or max_score == 0.0:
                max_score = tree_score
                max_tree = i

        optimal_seq.push_back(max_tree)
        selected_trees[max_tree] = True
        for k in xrange(sample_size):
            if curr_votes[k] != -1:
                if coverage[max_tree].index(k):
                    if curr_votes[k] + 1 >= 5:
                        curr_votes[k] = -1
                else:
                    if curr_votes[k] + n - j - 1 < 5:
                        curr_votes[k] = -1

    return optimal_seq


cdef Node optimize_plans(omap[int, vector[Node]]& plans, 
                         omap[int, vector[int]]& num_join_nodes,
                         vector[bool]& selected_trees, bool push_flag):
    py_map = {}
    cdef int i, j,m=0,n,k

    cdef vector[Node] plans_to_optimize, optimized_plans
    cdef vector[int] num_join_nodes_to_optimize

    selected_join_preds = {}
    for i in range(selected_trees.size()):
        if not selected_trees[i]:
            continue
        print i, plans[i].size()
        for j in range(plans[i].size()):
            if num_join_nodes[i][j] == 1:
                optimized_plans.push_back(plans[i][j])
                selected_join_preds[plans[i][j].children[0].predicates[0].feat_name] = True
            else:
                plans_to_optimize.push_back(plans[i][j])
                num_join_nodes_to_optimize.push_back(num_join_nodes[i][j])
                py_map[m] = plans[i][j].children[0].predicates[0].cost
                m += 1

    cdef Node curr_node
    cdef bool flag
    cdef vector[int] plans_to_update
    cdef vector[int] pred_index
    
    pyl = sorted(py_map, key=py_map.get, reverse=True)
    for k in pyl:
        flag = True
        curr_node = plans_to_optimize[k].children[0]
        m = num_join_nodes_to_optimize[k] 
        for n in range(1, m):
            curr_node = curr_node.children[0]
            if selected_join_preds.get(curr_node.predicates[0].feat_name) is not None:
                plans_to_update.push_back(k)
                pred_index.push_back(n)
                flag = False
                break
        if flag:
            optimized_plans.push_back(plans_to_optimize[k])
            selected_join_preds[plans_to_optimize[k].children[0].predicates[0].feat_name] = True            
    
    generate_new_plans(plans_to_optimize, plans_to_update, pred_index, 
                       optimized_plans)

    cdef vector[Node] reordered_plans
    cdef vector[bool] overlap_join_plans
    for i in range(optimized_plans.size()):                              
        if optimized_plans[i].children[0].predicates[0].sim_measure_type.compare("OVERLAP_COEFFICIENT") == 0:
            overlap_join_plans.push_back(True)
            reordered_plans.push_back(optimized_plans[i])
        else:
            overlap_join_plans.push_back(False)

    for i in range(overlap_join_plans.size()):
        if not overlap_join_plans[i]:
            reordered_plans.push_back(optimized_plans[i])

    cdef vector[Node] pushed_optimized_plans                                    
    cdef Node optimized_plan                                                    

    if push_flag:                                                                                
        push_filters(reordered_plans, pushed_optimized_plans)  

        for i in range(pushed_optimized_plans.size()):                                                         
            if i == 0:                                                          
                optimized_plan = pushed_optimized_plans[i]
            else:                                  
                optimized_plan = merge_plans(optimized_plan, pushed_optimized_plans[i])         
    else:
        for i in range(reordered_plans.size()):                                 
            if i == 0:                                                          
                optimized_plan = reordered_plans[i]                             
            else:                                                               
                optimized_plan = merge_plans(optimized_plan, reordered_plans[i])

    return optimized_plan

cdef void push_filters(vector[Node]& plans, vector[Node]& new_plans):
    cdef int i, j, k
    cdef vector[Node] nodes
    cdef string node_type                                                       
    cdef Node curr_node, new_node
    for i in range(plans.size()):
        curr_node = plans[i]
        nodes = vector[Node]()
        new_node = Node(curr_node.node_type)                            
        new_node.set_tree_id(curr_node.tree_id)                         
        new_node.set_rule_id(curr_node.rule_id)                         
        nodes.push_back(new_node)                                       
        curr_node = curr_node.children[0]  
        j = 1
        seen_tok = {}
        while curr_node.node_type.compare("OUTPUT") != 0:
            if curr_node.node_type.compare("JOIN") == 0:                                              
                new_node = Node(curr_node.node_type)                                              
                new_node.predicates.push_back(curr_node.predicates[0])                                           
                nodes.push_back(new_node)
                curr_node = curr_node.children[0]
                j += 1
                continue
            if (curr_node.predicates[0].tokenizer_type.compare("none") == 0 or 
                seen_tok.get(curr_node.predicates[0].tokenizer_type) is None):
                new_node = Node(curr_node.node_type)
                new_node.predicates.push_back(curr_node.predicates[0])                                      
                nodes.push_back(new_node)
                seen_tok[curr_node.predicates[0].tokenizer_type] = j
                j += 1
            else:
                nodes[seen_tok[curr_node.predicates[0].tokenizer_type]].predicates.push_back(curr_node.predicates[0])
                                                       
            curr_node = curr_node.children[0]      

        new_node = Node(curr_node.node_type)                                          
        new_node.set_tree_id(curr_node.tree_id)                                       
        new_node.set_rule_id(curr_node.rule_id)                                       
        nodes.push_back(new_node)

        for k in xrange(nodes.size() - 2, -1, -1):                              
            nodes[k].add_child(nodes[k+1])                                      
                                                                                
        new_plans.push_back(nodes[0])         


cdef void generate_new_plans(vector[Node]& old_plans,
                             vector[int]& plans_to_update, 
                             vector[int]& pred_index,
                             vector[Node]& new_plans):    
    cdef int i, j, k, pin, tree_id, rule_id
    cdef vector[Predicatecpp] preds
    cdef vector[Node] nodes
    cdef Node curr_node, new_node
    cdef bool join_pred
    cdef string node_type
    for i in range(pred_index.size()):
        
        preds.clear()
        
        tree_id = old_plans[plans_to_update[i]].tree_id
        rule_id = old_plans[plans_to_update[i]].rule_id
        curr_node = old_plans[plans_to_update[i]].children[0]
        
        while curr_node.node_type.compare("OUTPUT") != 0:
            preds.push_back(curr_node.predicates[0])
            curr_node = curr_node.children[0]
        
        nodes = vector[Node]()                                              
        node_type = "ROOT"                                                  
        new_node = Node(node_type)                                          
        new_node.set_tree_id(tree_id)                                  
        new_node.set_rule_id(rule_id)                                       
        nodes.push_back(new_node)                                           
        
        join_pred = True                                                    
                                                                        
        for j in range(preds.size()):
            pin = j
            if j == 0:
                pin = pred_index[i]
            elif j == pred_index[i]:
                pin = 0                                         
            node_type = "FILTER"                                            
            if join_pred:                                                   
                node_type = "JOIN"                                          
                join_pred = False                                           
                                                                                            
            new_node = Node(node_type)                                      
            new_node.predicates.push_back(preds[pin])               
            nodes.push_back(new_node)                                       
                                                                      
        node_type = "OUTPUT"                                                
        new_node = Node(node_type)                                          
        new_node.set_tree_id(tree_id)                                  
        new_node.set_rule_id(rule_id)                                       
        nodes.push_back(new_node)                                           
        for k in xrange(nodes.size() - 2, -1, -1):                          
            nodes[k].add_child(nodes[k+1])                                  
        
        new_plans.push_back(nodes[0])          

cdef double compute_cost_of_combined_plan(omap[int, vector[Node]]& plans, 
                                          omap[string, Coverage]& coverage,
                                          omap[int, Coverage]& tree_cov, 
                                          const int sample_size,
                                          vector[bool]& selected_trees):
    cdef Node stage1_plan, stage2_plan              
    cdef Coverage prev_coverage                                                                                  
    cdef int i, j, num_trees = selected_trees.size()
    cdef bool flag1, flag2
    flag1 = True
    flag2 = True  
    for i in range(num_trees):
        if selected_trees[i]:                                          
            prev_coverage.or_coverage(tree_cov[i])                                
            for j in range(plans[i].size()):                                        
                if flag1:                                                            
                    stage1_plan = plans[i][j]                                     
                    flag1 = False                                                    
                else:                                                               
                    stage1_plan = merge_plans(stage1_plan, plans[i][j])   
        else:
            for j in range(plans[i].size()):                                    
                if flag2:                                                       
                    stage2_plan = plans[i][j]                                   
                    flag2 = False                                               
                else:                                                           
                    stage2_plan = merge_plans(stage2_plan, plans[i][j])    
    cdef double selectivity, stage1_cost, stage2_cost
    stage1_cost = compute_plan_cost(stage1_plan, coverage, sample_size)    
    stage2_cost = compute_plan_cost(stage2_plan, coverage, sample_size)              
    selectivity = <double>prev_coverage.sum() / <double>sample_size
    return stage1_cost + selectivity*stage2_cost

cdef void find_random_subset(vector[bool]& selected_trees):
    cdef int num_trees = selected_trees.size(), num_trees_to_remove, i, j
    num_trees_to_remove = num_trees - (num_trees / 2) - 1                       
    i = 0
    while i < num_trees_to_remove:
        j = -1
        while j == -1 or (not selected_trees[j]):
            j = random.randint(0, num_trees - 1)
        selected_trees[j] = False
        i += 1     

cdef void find_optimal_subset(omap[int, vector[Node]]& plans, 
                         omap[string, Coverage]& coverage,
                         omap[int, Coverage]& tree_cov,
                         vector[bool]& selected_trees,
                         const int sample_size, num_trees_for_blocking=6):

    cdef Node combined_plan
    cdef int i, j, num_trees = selected_trees.size(), num_trees_to_remove
    cdef bool flag

    flag = True
   
    for i in range(num_trees):
        for j in range(plans[i].size()):
            if flag:
                combined_plan = plans[i][j]
                flag = False
            else:
                combined_plan = merge_plans(combined_plan, plans[i][j])        
   
    cdef double cost, curr_cost = compute_plan_cost(combined_plan, coverage, sample_size)
    
    #num_trees_to_remove = num_trees - (num_trees / 2) - 1                                           
    num_trees_to_remove = num_trees - num_trees_for_blocking
    for j in xrange(num_trees_to_remove):                                       
        max_reduction = 0.0
        max_cost = 0.0                                                         
        max_tree = -1                                                           
        for i in xrange(num_trees):                                                     
            if not selected_trees[i]:                                               
                continue
            selected_trees[i] = False
        
            cost = compute_cost_of_combined_plan(plans, coverage, tree_cov, 
                                                 sample_size, selected_trees)
            selected_trees[i] = True
            if curr_cost - cost >= max_reduction or max_reduction == 0.0:
                max_reduction = curr_cost - cost
                max_cost = cost
                max_tree = i
        selected_trees[max_tree] = False
        curr_cost = max_cost


cdef omap[int, vector[Node]] get_plans_for_rules(vector[Tree]& trees,                       
                                     omap[string, Coverage]& coverage,          
                                     omap[int, Coverage]& tree_cov,             
                                     const int sample_size,                     
                                     vector[Tree]& sel_trees,                   
                                     vector[Tree]& rem_trees,                   
                                     bool reuse_flag, bool push_flag, tree_list):
    cdef omap[int, vector[Node]] plans                                          
    cdef omap[int, vector[int]] num_join_nodes                                  
    cdef int i, j = 0, k, n=trees.size(), max_tree, num_trees_to_select         
                                                                                
    cdef vector[Tree] tmp_vec                                                   
    for i in xrange(n):                                                         
        tmp_vec.push_back(trees[i])                                             
        generate_local_optimal_plans(tmp_vec, coverage, sample_size, plans[i], num_join_nodes[i], False)
        tmp_vec.clear()
    return plans    

cdef Node get_default_execution_plan(vector[Tree]& trees,
                                     omap[string, Coverage]& coverage,
                                     omap[int, Coverage]& tree_cov,            
                                     const int sample_size,
                                     vector[Tree]& sel_trees, 
                                     vector[Tree]& rem_trees,
                                     bool reuse_flag, bool push_flag, tree_list, 
                                     num_trees_for_blocking, bool random_order):                   
    cdef omap[int, vector[Node]] plans
    cdef omap[int, vector[int]] num_join_nodes                                                        
    cdef Node new_global_plan, curr_global_plan, tmp_node                                 
    cdef vector[int] optimal_seq                                                
    cdef vector[bool] selected_trees                                            
    cdef Coverage prev_coverage                                                 
    cdef int i, j = 0, k, n=trees.size(), max_tree, num_trees_to_select                
    cdef double max_score, tree_score, plan_cost                                           
    
    cdef vector[Tree] tmp_vec
    for i in xrange(n):
        tmp_vec.push_back(trees[i])
        generate_local_optimal_plans(tmp_vec, coverage, sample_size, plans[i], num_join_nodes[i], random_order)           
        tmp_vec.clear()
                                                            
#    num_trees_to_select = (n / 2) + 1
    num_trees_to_select = num_trees_for_blocking                                        
#    num_trees_to_select = n
    for i in xrange(n):                                                         
        selected_trees.push_back(True)                                         
    '''                                                                       
    for j in xrange(num_trees_to_select):                                       
        max_score = 0.0                                                         
        max_tree = -1                                                           
        for i in xrange(n):
            if selected_trees[i]:                                               
                continue                                                        
            if j == 0:
                new_global_plan = plans[i][0]
                k = 1
                while k < plans[i].size():
                    new_global_plan = merge_plans(new_global_plan, plans[i][k])
                    k += 1
                plan_cost = compute_plan_cost(new_global_plan, coverage, sample_size)                                                             
                tree_score = (1.0 - (tree_cov[i].sum() / sample_size)) / plan_cost
            else:
                new_global_plan = curr_global_plan
                k = 0
                while k < plans[i].size():                         
                    new_global_plan = merge_plans(new_global_plan, plans[i][k])
                    k += 1        
                plan_cost = compute_plan_cost(new_global_plan, coverage, sample_size)                              
                tree_score = (1.0 - (prev_coverage.and_sum(tree_cov[i]) / sample_size)) / plan_cost
                                                                                
                                                                                
            if tree_score > max_score:                                          
                max_score = tree_score                                          
                max_tree = i                                                    
                                                                     
        if j == 0:
            curr_global_plan = plans[max_tree][0]                                   
            k = 1                                                           
            while k < plans[max_tree].size():                                      
                curr_global_plan = merge_plans(curr_global_plan, plans[max_tree][k]) 
                k += 1   
        else:
            k = 0                                                               
            while k < plans[max_tree].size():                                   
                curr_global_plan = merge_plans(curr_global_plan, plans[max_tree][k])
                k += 1

        selected_trees[max_tree] = True                                         
        if j == 0:                                                              
            prev_coverage.or_coverage(tree_cov[max_tree])                       
        else:                                                                   
            prev_coverage.and_coverage(tree_cov[max_tree])                      
    '''
#    cit_trees = [0, 2, 3, 5]
    
#    find_optimal_subset(plans, coverage, tree_cov, selected_trees, sample_size)                                                                            
    if len(tree_list) > 1:
        for i in xrange(n):
            selected_trees[i] = False
        for i in tree_list:
            selected_trees[i] = True
    else:
        find_optimal_subset(plans, coverage, tree_cov, selected_trees, sample_size, num_trees_to_select)                                                             

#    find_random_subset(selected_trees)
    print 'total number of trees : ' , n
    print 'selected trees : '
 
    for i in xrange(n):
        if not selected_trees[i]:
            rem_trees.push_back(trees[i])
        else:
            sel_trees.push_back(trees[i])

    if reuse_flag:
        return optimize_plans(plans, num_join_nodes, selected_trees, push_flag)

    cdef vector[Node] pushed_plans                                   
    cdef Node combined_plan                                                     
    cdef vector[Node] overall_plans

    for i in xrange(n):
        for j in xrange(plans[i].size()):
            overall_plans.push_back(plans[i][j])

    if push_flag:
        push_filters(overall_plans, pushed_plans)                       
                                                                                
        for i in range(pushed_plans.size()):                                     
            if i == 0:                                                              
                combined_plan = pushed_plans[i]                                 
            else:                                                                   
                combined_plan = merge_plans(combined_plan, pushed_plans[i]) 
    else:
        for i in range(overall_plans.size()):                                    
            if i == 0:                                                          
                combined_plan = overall_plans[i]                                 
            else:                                                               
                combined_plan = merge_plans(combined_plan, overall_plans[i])   

    return combined_plan 

cdef pair[vector[int], int] get_random_order(pair[vector[int], int] optimal_seq):
    cdef pair[vector[int], int] random_order
    cdef int total_nodes=optimal_seq.first.size(), join_nodes = optimal_seq.second
    cdef vector[int] rand_seq

    used = [False for _ in xrange(total_nodes)]
    rand_seq.push_back(optimal_seq.first[0])
    used[0] = True

    cdef int i = 1, j
    while i < join_nodes:
        j = random.randint(1, join_nodes - 1)
        if not used[j]:
            rand_seq.push_back(optimal_seq.first[j])
            used[j] = True
            i += 1
    i = 0
    while i < total_nodes - join_nodes:
        j = random.randint(join_nodes, total_nodes - 1)
        if not used[j]:
            rand_seq.push_back(optimal_seq.first[j])
            used[j] = True
            i += 1

    random_order.first = rand_seq
    random_order.second = join_nodes
    return random_order

cdef void generate_local_optimal_plans(vector[Tree]& trees, 
                                       omap[string, Coverage]& coverage, 
                                       int sample_size, 
                                       vector[Node]& plans, vector[int]& num_join_nodes,
                                       bool random_order):
    cdef Tree tree
    cdef Rule rule
    cdef pair[vector[int], int] optimal_seq
    cdef vector[Node] nodes
    cdef Node root, new_node, curr_node
    cdef string node_type
    cdef int i, rule_id, tree_id = 0
    cdef bool join_pred

    for tree in trees:
        rule_id = 0
        for rule in tree.rules:
            nodes = vector[Node]()
            optimal_seq = get_optimal_predicate_seq(rule.predicates, coverage, sample_size)
            if random_order:
                optimal_seq = get_random_order(optimal_seq)
            node_type = "ROOT"
            new_node = Node(node_type)                                          
            new_node.set_tree_id(tree.tree_id)                                  
            new_node.set_rule_id(rule_id)   
            nodes.push_back(new_node)
            join_pred = True

            for i in optimal_seq.first:
                node_type = "FILTER"
                if join_pred:
                    node_type = "JOIN"
                    join_pred = False

                new_node = Node(node_type)
                new_node.predicates.push_back(rule.predicates[i])
                nodes.push_back(new_node)
    
            node_type = "OUTPUT"
            new_node = Node(node_type)
            new_node.set_tree_id(tree.tree_id)
            new_node.set_rule_id(rule_id)
            nodes.push_back(new_node)
            for i in xrange(nodes.size() - 2, -1, -1):
                nodes[i].add_child(nodes[i+1])
            plans.push_back(nodes[0])
            num_join_nodes.push_back(optimal_seq.second)
            rule_id += 1
        tree_id += 1

# Ordering a set of predicates            
cdef pair[vector[int], int] get_optimal_predicate_seq(
                                           vector[Predicatecpp]& predicates,
                                           omap[string, Coverage]& coverage,
                                           const int sample_size):                                      
    cdef vector[int] valid_predicates, invalid_predicates
    cdef pair[vector[int], int] optimal_seq
    cdef vector[bool] selected_predicates
    cdef Predicatecpp predicate
    cdef int i, max_pred, j, n=0
    cdef double max_score, pred_score

    for i in xrange(predicates.size()):                                                
        if predicates[i].is_join_predicate():                                 
            valid_predicates.push_back(i)                                  
            n += 1
        else:                                                                   
            invalid_predicates.push_back(i)
        selected_predicates.push_back(False)
    
                                
    if n == 0:                                              
        print 'invalid rf'                                                      
                                                                                                                        
    max_score = 0.0                                                               
    max_pred = -1                                                         
    cdef Coverage prev_coverage
                                                        
    for i in valid_predicates:                                      
        pred_score = (1.0 - (coverage[predicates[i].pred_name].count / sample_size)) / predicates[i].cost     
                                                                                
        if pred_score > max_score or max_score == 0.0:                                              
            max_score = pred_score                                              
            max_pred = i                   
                               
    optimal_seq.first.push_back(max_pred)              
    selected_predicates[max_pred] = True                                  

    prev_coverage.or_coverage(coverage[predicates[max_pred].pred_name])                   
    
    j = 1                                                                            
    while j < n:                  
        max_score = -1                                                          
        max_pred = -1                                                     
                                                                                
        for i in valid_predicates:                                  
            if selected_predicates[i]:                              
                continue                                                        
                                                                               
            pred_score = (1.0 - (prev_coverage.and_sum(coverage[predicates[i].pred_name]) / sample_size)) / predicates[i].cost             
            if pred_score > max_score:                                          
                max_score = pred_score                                          
                max_pred = i                                              
                                                                                
        optimal_seq.first.push_back(max_pred)
        selected_predicates[max_pred] = True                              
        prev_coverage.and_coverage(coverage[predicates[max_pred].pred_name])
        j += 1 
    optimal_seq.first.insert(optimal_seq.first.end(), invalid_predicates.begin(),
                       invalid_predicates.end())
    optimal_seq.second = valid_predicates.size()                            
    return optimal_seq         

cdef vector[Rule] extract_pos_rules_from_tree(d_tree, feature_table):
    feature_names = list(feature_table.index)                                   
    # Get the left, right trees and the threshold from the tree                 
    left = d_tree.tree_.children_left                                             
    right = d_tree.tree_.children_right                                           
    threshold = d_tree.tree_.threshold                                            
                                                                                
    # Get the features from the tree                                            
    features = [feature_names[i] for i in d_tree.tree_.feature]                   
    value = d_tree.tree_.value                                                    
                                                                                
    cdef vector[Rule] rules                                                        
    traverse(0, left, right, features, threshold, value, feature_table, 0, [], rules)                        

    return rules
                                                                                
cdef void traverse(node, left, right, features, threshold, value, feature_table, depth, cache, vector[Rule]& rules):
    if node == -1:                                                          
        return                                                              
    cdef vector[Predicatecpp] preds                                     
    cdef Predicatecpp pred   
    cdef Rule rule                                                      
    if threshold[node] != -2:                                               
            # node is not a leaf node                                           
        feat_row = feature_table.ix[features[node]]                         
        p = Predicate(features[node],                                       
                          feat_row['sim_measure_type'],                         
                          feat_row['tokenizer_type'],                           
                          feat_row['sim_function'],                             
                          feat_row['tokenizer'], '<=', threshold[node], 0)
#            p.set_name(features[node]+' <= '+str(threshold[node]))                                                         
        cache.insert(depth, p)                                              
        traverse(left[node], left, right, features, threshold, value, feature_table, depth+1, cache, rules)
        prev_pred = cache.pop(depth)                                        
        feat_row = feature_table.ix[features[node]]                         
        p = Predicate(features[node],                                       
                      feat_row['sim_measure_type'],                         
                      feat_row['tokenizer_type'],                           
                      feat_row['sim_function'],                             
                      feat_row['tokenizer'], '>', threshold[node], 0)
#            p.set_name(features[node]+' > '+str(threshold[node]))                                               
        cache.insert(depth, p)                                              
        traverse(right[node], left, right, features, threshold, value, feature_table, depth+1, cache, rules)
        prev_pred = cache.pop(depth)                                        
    else:                                                                   
            # node is a leaf node                                               
        if value[node][0][0] <= value[node][0][1]:
            pred_dict = {}
            for i in xrange(depth):
                if pred_dict.get(cache[i].feat_name+cache[i].comp_op) is None:
                    pred_dict[cache[i].feat_name+cache[i].comp_op] = i
                    continue
                if cache[i].comp_op == '<=':
                    if cache[i].threshold > cache[pred_dict[cache[i].feat_name+cache[i].comp_op]].threshold:
                        pred_dict[cache[i].feat_name+cache[i].comp_op] = i
                else:
                    if cache[i].threshold < cache[pred_dict[cache[i].feat_name+cache[i].comp_op]].threshold:
                        pred_dict[cache[i].feat_name+cache[i].comp_op] = i    

            for k in pred_dict.keys():
                i = pred_dict[k]
                pred_name = cache[i].feat_name+cache[i].comp_op+str(cache[i].threshold) 
                pred = Predicatecpp(pred_name, cache[i].feat_name, cache[i].sim_measure_type, cache[i].tokenizer_type, cache[i].comp_op, cache[i].threshold)                  
                preds.push_back(pred)
            rule = Rule(preds)                                        
#                r.set_name('r'+str(start_rule_id + len(rule_set.rules)+1))      
            rules.push_back(rule)                                            
#            print 'pos rule: ', cache[0:depth]                              
                                                                                
cdef vector[Tree] extract_pos_rules_from_rf(rf, feature_table):                               
    cdef vector[Tree] trees
    cdef vector[Rule] rules
    cdef Tree tree                                                             
    rule_id = 1                                                                 
    predicate_id = 1                                                            
    tree_id = 0                                                                 
    for dt in rf.estimators_:                                                   
        rules = extract_pos_rules_from_tree(dt, feature_table)                                                              
        tree = Tree(rules)
        tree.set_tree_id(tree_id)                                                          
#        rs.set_name('t'+str(tree_id))                                           
        tree_id += 1                                                            
#        rule_id += tree.rules.size()                                             
        trees.push_back(tree)                                                    
    return trees


cdef Node merge_plans(Node plan1, Node plan2):                                 
    cdef Node plan2_node = plan2.children[0]                                         
    cdef Predicatecpp pred1, pred2
    cdef string node_type = "SELECT"
    pred2 = plan2_node.predicates[0]
    cdef int i=0

    while i < plan1.children.size():
#        print 'sib : ', plan1.children[i].node_type                              
        if nodes_can_be_merged(plan1.children[i], plan2_node, 
                               plan1.children[i].predicates[0], pred2):
            break
        i += 1     

    if i == plan1.children.size():
        plan1.add_child(plan2.children[0])
        return plan1
 
#    print 't1', plan2_node.node_type                                
    cdef vector[Node] child_nodes_to_move
    cdef Node node_to_move
    cdef int k
    if plan2_node.node_type.compare("JOIN") == 0:                              
        pred1 = plan1.children[i].predicates[0]                                                                        
        if ((pred1.threshold < pred2.threshold) or                  
            (pred1.threshold == pred2.threshold and                 
             pred1.comp_op.compare(">=") == 0 and 
             pred2.comp_op.compare(">") == 0)):      
#            print 't2'
            plan2_node.set_node_type(node_type)                         
            plan1.children[i].add_child(plan2_node)                      
                                                                                
        elif ((pred1.threshold > pred2.threshold) or                
              (pred1.threshold == pred2.threshold and               
               pred1.comp_op.compare(">") == 0 and 
               pred2.comp_op.compare(">=") == 0)):    
#            print 't3'                                              
            plan1.children[i].set_node_type(node_type)
            for k in xrange(plan1.children[i].children.size()):
                if plan1.children[i].children[k].node_type.compare("SELECT") == 0:
                    child_nodes_to_move.push_back(plan1.children[i].children[k])                          
            for node_to_move in child_nodes_to_move:
                plan2_node.add_child(node_to_move)
                plan1.children[i].remove_child(node_to_move)

            plan2_node.add_child(plan1.children[i])        
            plan1.remove_child(plan1.children[i])              
            plan1.add_child(plan2_node)               
                                                                                
        elif pred1.threshold == pred2.threshold:                    
#            print 't4'                                                      
            plan1.children[i].add_child(plan2_node.children[0])
    else:
        print 'invalid rf'                                                             

    return plan1

cdef bool nodes_can_be_merged(Node& node1, Node& node2, Predicatecpp& pred1, 
                              Predicatecpp& pred2):                            
    if node1.node_type.compare(node2.node_type) != 0:                                      
        return False                                                            
    if pred1.feat_name.compare(pred2.feat_name) != 0:                                      
        return False                                                            
    return are_comp_ops_compatible(pred1.comp_op, pred2.comp_op, node1.node_type)
                                                                                
cdef bool are_comp_ops_compatible(comp_op1, comp_op2, node_type):                     
    if node_type == "FILTER":                                                   
        return True                                                             
    if node_type == "SELECT":
        return comp_op1 == comp_op2                                
    if comp_op1 in ['<', '<='] and comp_op2 in ['>' '>=']:                      
        return False                                                            
    if comp_op1 in ['>', '>='] and comp_op2 in ['<', '<=']:                     
        return False                                                            
    return True 

cdef Node generate_overall_plan(vector[Node] plans):
    cdef Node combined_plan = plans[0]
    cdef int i=1
    print 'before merge size : ', combined_plan.children.size()
    while i < plans.size():
        combined_plan = merge_plans(combined_plan, plans[i])
        i += 1
#        print 'i = ', i, ' , num child nodes : ', combined_plan.children.size()
    return combined_plan
