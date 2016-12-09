
from libcpp cimport bool
from libcpp.vector cimport vector                                               
from libcpp.string cimport string                                              
from libcpp.map cimport map as omap                                             

from py_stringsimjoin.apply_rf.sim_functions cimport cosine, dice, jaccard, cosine_str, dice_str, jaccard_str      
from py_stringsimjoin.apply_rf.inverted_index cimport InvertedIndex             
 

cdef int get_sim_type(const string& sim_measure_type):                          
    if sim_measure_type.compare('COSINE') == 0: # COSINE                                                  
        return 0                                                                
    elif sim_measure_type.compare('DICE') == 0: # DICE                                                  
        return 1                                                                
    elif sim_measure_type.compare("JACCARD") == 0: # JACCARD:                                              
        return 2                                                                
                                                                                
cdef simfnptr get_sim_function(const int sim_type) nogil:                       
    if sim_type == 0: # COSINE                                                  
        return cosine                                                           
    elif sim_type == 1: # DICE                                                  
        return dice                                                             
    elif sim_type == 2: # JACCARD:                                              
        return jaccard  

cdef simfnptr_str get_sim_function_str(const int sim_type) nogil:                       
    if sim_type == 0: # COSINE                                                  
        return cosine_str                                                           
    elif sim_type == 1: # DICE                                                  
        return dice_str                                                             
    elif sim_type == 2: # JACCARD:                                              
        return jaccard_str      

cdef bool eq_compare(double val1, double val2) nogil:                           
    return val1 == val2                                                         
                                                                                
cdef bool le_compare(double val1, double val2) nogil:                           
    return val1 <= val2                                                         
                                                                                
cdef bool lt_compare(double val1, double val2) nogil:                           
    return val1 < val2                                                          
                                                                                
cdef bool ge_compare(double val1, double val2) nogil:                           
    return val1 >= val2                                                         
                                                                                
cdef bool gt_compare(double val1, double val2) nogil:                           
    return val1 > val2                                                          
                                                                                
cdef int get_comp_type(const string& comp_op):                                  
    if comp_op.compare('<') == 0:                                               
        return 0                                                                
    elif comp_op.compare('<=') == 0:                                            
        return 1                                                                
    elif comp_op.compare('>') == 0:                                             
        return 2                                                                
    elif comp_op.compare('>=') == 0:                                            
        return 3                                                                
                                                                                
cdef compfnptr get_comparison_function(const int comp_type) nogil:              
    if comp_type == 0:                                                          
        return lt_compare                                                       
    elif comp_type == 1:                                                        
        return le_compare                                                       
    elif comp_type == 2:                                                        
        return gt_compare                                                       
    elif comp_type == 3:                                                        
        return ge_compare 

cdef int int_min(int a, int b) nogil: 
    return a if a <= b else b          

cdef int int_max(int a, int b) nogil: 
    return a if a >= b else b          

cdef void build_inverted_index(vector[vector[int]]& token_vectors, InvertedIndex &inv_index):
    cdef vector[int] tokens, size_vector                                        
    cdef int i, j, m, n=token_vectors.size()                                    
    cdef omap[int, vector[int]] index                                           
    for i in range(n):                                                          
        tokens = token_vectors[i]                                               
        m = tokens.size()                                                       
        size_vector.push_back(m)                                                
        for j in range(m):                                                      
            index[tokens[j]].push_back(i)                                       
    inv_index.set_fields(index, size_vector)   
 ##
cdef void build_prefix_index(vector[vector[int]]& token_vectors, int qval, double threshold, InvertedIndex &inv_index):
    cdef vector[int] tokens, size_vector                                        
    cdef int i, j, m, n=token_vectors.size(), prefix_length                     
    cdef omap[int, vector[int]] index                                           
    for i in range(n):                                                          
        tokens = token_vectors[i]                                               
        m = tokens.size()                                                       
        size_vector.push_back(m)                                                
        prefix_length = int_min(<int>(qval * threshold + 1), m)                 
                                                                                
        for j in range(prefix_length):                                          
            index[tokens[j]].push_back(i)                                       
    inv_index.set_fields(index, size_vector)        
